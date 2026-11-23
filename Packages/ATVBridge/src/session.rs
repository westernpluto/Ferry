//! Connection handling: pairing, tunnel setup and the device services we use.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use idevice::afc::AfcClient;
use idevice::afc::opcode::AfcFopenMode;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::{IdeviceError, RsdService};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;

use crate::ipa::IpaInfo;
use crate::{AtvProgressCallback, BridgeResult, Ctx};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const UPLOAD_CHUNK: usize = 1024 * 1024;
const STAGING_DIR: &str = "PublicStaging";
const STAGING_FILE: &str = "PublicStaging/ferry.ipa";

/// Host + port of a Bonjour-advertised (or manually entered) service.
pub struct Endpoint {
    host: String,
    port: u16,
}

impl Endpoint {
    pub fn new(host: &str, port: u16) -> Self {
        Self {
            host: crate::addr::clean_host(host),
            port,
        }
    }

    /// Resolve and connect, trying each address in turn. Returns the stream and
    /// the address that worked so other ports on the same device can be reached.
    async fn connect(&self) -> BridgeResult<(TcpStream, SocketAddr)> {
        let addrs = crate::addr::resolve(&self.host, self.port).await?;
        let mut last_err = String::new();
        for addr in addrs {
            match connect_addr(addr).await {
                Ok(s) => return Ok((s, addr)),
                Err(e) => last_err = e,
            }
        }
        Err(last_err)
    }
}

async fn connect_addr(addr: SocketAddr) -> BridgeResult<TcpStream> {
    match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
        Ok(Ok(s)) => {
            let _ = s.set_nodelay(true);
            Ok(s)
        }
        Ok(Err(e)) => Err(format!("could not connect to {addr}: {e}")),
        Err(_) => Err(format!("timed out connecting to {addr}")),
    }
}

fn dev_err(context: &str) -> impl Fn(IdeviceError) -> String + '_ {
    move |e| format!("{context}: {e}")
}

/// Pair with a TV in pairing mode, then reconnect once to prove the new record
/// works before handing it back.
pub async fn pair(
    ep: &Endpoint,
    host_name: &str,
    pin: impl Fn() -> String,
) -> BridgeResult<(RpPairingFile, String)> {
    let (stream, _) = ep.connect().await?;
    let mut rpf = RpPairingFile::generate(host_name);
    let cancelled = Arc::new(AtomicBool::new(false));
    let peer: serde_json::Value;
    {
        let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), host_name);
        let cancelled = cancelled.clone();
        let res = rpc
            .connect(&mut rpf, || {
                let p = pin();
                if p.is_empty() {
                    cancelled.store(true, Ordering::SeqCst);
                }
                async move { p }
            })
            .await;
        if cancelled.load(Ordering::SeqCst) {
            return Err("Pairing cancelled".into());
        }
        res.map_err(|e| {
            format!(
                "Pairing failed (check the PIN and that the Apple TV is still in pairing mode): {e}"
            )
        })?;
        peer = match rpc.paired_peer_device() {
            Ok(p) => serde_json::json!({
                "name": p.name,
                "model": p.model,
                "udid": p.remotepairing_udid,
            }),
            // Already paired: pair-verify succeeded without a new pair-setup.
            Err(_) => serde_json::json!({}),
        };
    }

    // Verify. Some tvOS builds close the pairing-mode service after a pair, so
    // a failure here is not fatal: the record is still good if pairing passed.
    if let Ok((stream, _)) = ep.connect().await {
        let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), host_name);
        let needed_pin = Arc::new(AtomicBool::new(false));
        let flag = needed_pin.clone();
        let _ = rpc
            .connect(&mut rpf, || {
                flag.store(true, Ordering::SeqCst);
                async { String::new() }
            })
            .await;
        if needed_pin.load(Ordering::SeqCst) {
            return Err("The Apple TV did not keep the pairing. Please try again.".into());
        }
    }
    Ok((rpf, peer.to_string()))
}

/// Reports progress to the C callback, if one was given.
pub struct Progress {
    cb: Option<AtvProgressCallback>,
    ctx: Ctx,
}

impl Progress {
    pub fn new(cb: Option<AtvProgressCallback>, ctx: Ctx) -> Self {
        Self { cb, ctx }
    }

    pub fn report(&self, phase: u32, percent: u32, status: &str) {
        if let Some(cb) = self.cb {
            let s = std::ffi::CString::new(status.replace('\0', " ")).unwrap_or_default();
            cb(self.ctx.0, phase, percent.min(100), s.as_ptr());
        }
    }
}

/// A verified connection with a CoreDevice tunnel and RSD service list.
pub struct Session {
    // Kept alive for the lifetime of the tunnel.
    _control: RemotePairingClient<RpPairingSocket<TcpStream>>,
    adapter: AdapterHandle,
    handshake: RsdHandshake,
}

impl Session {
    pub async fn open(
        ep: &Endpoint,
        host_name: &str,
        mut rpf: RpPairingFile,
    ) -> BridgeResult<Self> {
        let (stream, addr) = ep.connect().await?;
        let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), host_name);

        let wants_pin = Arc::new(AtomicBool::new(false));
        let flag = wants_pin.clone();
        let res = rpc
            .connect(&mut rpf, || {
                flag.store(true, Ordering::SeqCst);
                async { String::new() }
            })
            .await;
        if wants_pin.load(Ordering::SeqCst) {
            return Err(
                "This Apple TV no longer accepts the saved pairing. Remove it and pair again."
                    .into(),
            );
        }
        res.map_err(dev_err("Pair verification failed"))?;

        let tunnel_port = rpc
            .create_tcp_listener()
            .await
            .map_err(dev_err("Apple TV refused to open a tunnel (are you connected to the _remotepairing._tcp service?)"))?;
        let mut tunnel_addr = addr;
        tunnel_addr.set_port(tunnel_port);
        let tunnel_stream = connect_addr(tunnel_addr).await?;
        let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
            .await
            .map_err(dev_err("Tunnel handshake failed"))?;

        let client_ip: std::net::IpAddr = tunnel
            .info
            .client_address
            .parse()
            .map_err(|e| format!("bad tunnel client address: {e}"))?;
        let server_ip: std::net::IpAddr = tunnel
            .info
            .server_address
            .parse()
            .map_err(|e| format!("bad tunnel server address: {e}"))?;
        let mtu = tunnel.info.mtu as usize;
        let rsd_port = tunnel.info.server_rsd_port;

        let raw = tunnel.into_inner();
        let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
        adapter.set_mss(mtu.clamp(1280, 8192) - 60);
        let mut adapter = adapter.to_async_handle();

        let rsd_stream = adapter
            .connect(rsd_port)
            .await
            .map_err(|e| format!("could not reach RSD through tunnel: {e}"))?;
        let handshake = RsdHandshake::new(rsd_stream)
            .await
            .map_err(dev_err("RSD handshake failed"))?;

        Ok(Self {
            _control: rpc,
            adapter,
            handshake,
        })
    }

    pub fn device_info_json(&self) -> String {
        let p = &self.handshake.properties;
        let get = |k: &str| p.get(k).and_then(|v| v.as_string()).map(str::to_string);
        let mut out = serde_json::Map::new();
        out.insert(
            "udid".into(),
            get("UniqueDeviceID")
                .unwrap_or_else(|| self.handshake.uuid.clone())
                .into(),
        );
        for (json_key, keys) in [
            ("name", &["DeviceName", "ProductName"][..]),
            ("productType", &["ProductType"][..]),
            ("osVersion", &["OSVersion", "ProductVersion"][..]),
            ("buildVersion", &["BuildVersion"][..]),
            ("deviceClass", &["DeviceClass"][..]),
        ] {
            if let Some(v) = keys.iter().find_map(|k| get(k)) {
                out.insert(json_key.into(), v.into());
            }
        }
        serde_json::Value::Object(out).to_string()
    }

    pub async fn install(
        &mut self,
        ipa: &Path,
        info: &IpaInfo,
        progress: &Progress,
    ) -> BridgeResult<()> {
        if !info.is_tvos() {
            return Err(format!(
                "{} is built for {}, not tvOS. Only tvOS apps can be installed on an Apple TV.",
                info.name.as_deref().unwrap_or(&info.bundle_id),
                if info.platforms.is_empty() {
                    "an unknown platform".to_string()
                } else {
                    info.platforms.join(", ")
                }
            ));
        }

        // Upload to PublicStaging in chunks so we can report progress.
        let mut file = tokio::fs::File::open(ipa)
            .await
            .map_err(|e| format!("could not open IPA: {e}"))?;
        let total = file
            .metadata()
            .await
            .map_err(|e| format!("could not read IPA size: {e}"))?
            .len()
            .max(1);

        let mut afc = AfcClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(dev_err("Could not start file service"))?;
        if afc.get_file_info(STAGING_DIR).await.is_err() {
            afc.mk_dir(STAGING_DIR)
                .await
                .map_err(dev_err("Could not create staging folder"))?;
        }
        {
            let mut fd = afc
                .open(STAGING_FILE, AfcFopenMode::WrOnly)
                .await
                .map_err(dev_err("Could not create staging file"))?;
            let mut buf = vec![0u8; UPLOAD_CHUNK];
            let mut sent: u64 = 0;
            let mut last_pct = u32::MAX;
            let upload = async {
                loop {
                    let n = file
                        .read(&mut buf)
                        .await
                        .map_err(|e| format!("could not read IPA: {e}"))?;
                    if n == 0 {
                        break;
                    }
                    fd.write_entire(&buf[..n])
                        .await
                        .map_err(dev_err("Upload failed"))?;
                    sent += n as u64;
                    let pct = (sent * 100 / total) as u32;
                    if pct != last_pct {
                        last_pct = pct;
                        progress.report(0, pct, "Uploading");
                    }
                }
                Ok::<_, String>(())
            }
            .await;
            let closed = fd.close().await.map_err(dev_err("Upload failed"));
            upload?;
            closed?;
        }
        drop(afc);

        progress.report(1, 0, "Installing");
        let mut inst = InstallationProxyClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(dev_err("Could not start installer service"))?;
        let options = plist::Value::Dictionary(
            [(
                "CFBundleIdentifier".to_string(),
                plist::Value::String(info.bundle_id.clone()),
            )]
            .into_iter()
            .collect(),
        );
        let res = inst
            .install_with_callback(
                STAGING_FILE,
                Some(options),
                |(pct, _): (u64, ())| {
                    progress.report(1, pct as u32, "Installing");
                    async {}
                },
                (),
            )
            .await
            .map_err(|e| format!("Install failed: {e}"));

        // Best-effort cleanup of the staged package.
        if let Ok(mut afc) = AfcClient::connect_rsd(&mut self.adapter, &mut self.handshake).await {
            let _ = afc.remove(STAGING_FILE).await;
        }

        res?;
        progress.report(1, 100, "Installed");
        Ok(())
    }

    pub async fn list_apps(&mut self) -> BridgeResult<String> {
        let mut inst = InstallationProxyClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(dev_err("Could not start installer service"))?;
        let apps = inst
            .get_apps(Some("User"), None)
            .await
            .map_err(dev_err("Could not list apps"))?;

        let mut list: Vec<serde_json::Value> = apps
            .into_iter()
            .map(|(bundle_id, v)| {
                let d = v.as_dictionary();
                let get = |k: &str| {
                    d.and_then(|d| d.get(k))
                        .and_then(|v| v.as_string())
                        .map(str::to_string)
                };
                serde_json::json!({
                    "name": get("CFBundleDisplayName").or_else(|| get("CFBundleName")).unwrap_or_else(|| bundle_id.clone()),
                    "version": get("CFBundleShortVersionString").or_else(|| get("CFBundleVersion")),
                    "bundleId": bundle_id,
                })
            })
            .collect();
        list.sort_by_key(|v| v["name"].as_str().unwrap_or_default().to_lowercase());
        Ok(serde_json::Value::Array(list).to_string())
    }

    pub async fn uninstall(&mut self, bundle_id: &str, progress: &Progress) -> BridgeResult<()> {
        let mut inst = InstallationProxyClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(dev_err("Could not start installer service"))?;
        inst.uninstall_with_callback(
            bundle_id,
            None,
            |(pct, _): (u64, ())| {
                progress.report(1, pct as u32, "Removing");
                async {}
            },
            (),
        )
        .await
        .map_err(|e| format!("Uninstall failed: {e}"))
    }
}
