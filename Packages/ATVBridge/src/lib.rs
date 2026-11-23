//! C bridge for Ferry's Apple TV support (from iOStoATV).
//!
//! Exposes a small, synchronous C API over the `idevice` crate so the Swift
//! app can pair with an Apple TV over Wi-Fi (RemotePairing, tvOS 17+), open a
//! CoreDevice tunnel, and install / list / uninstall apps.
//!
//! Every function blocks the calling thread, so call them off the main thread.
//! Functions return `NULL` on success or an error message that the caller must
//! free with `atv_free_string`.

mod addr;
mod ipa;
mod mdns_probe;
mod session;

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

use idevice::remote_pairing::RpPairingFile;

pub use session::Endpoint;

/// Called when the Apple TV shows a PIN. Write a NUL-terminated PIN into
/// `out_pin` (capacity `out_cap`). Leave it empty to cancel pairing.
pub type AtvPinCallback = extern "C" fn(ctx: *mut c_void, out_pin: *mut c_char, out_cap: usize);

/// Progress for install / uninstall. `phase` is 0 = uploading, 1 = installing.
/// `percent` is 0...100. `status` is a short NUL-terminated description.
pub type AtvProgressCallback =
    extern "C" fn(ctx: *mut c_void, phase: u32, percent: u32, status: *const c_char);

pub(crate) type BridgeResult<T> = Result<T, String>;

fn err_ptr(msg: impl Into<String>) -> *mut c_char {
    let msg = msg.into().replace('\0', " ");
    CString::new(msg).unwrap_or_default().into_raw()
}

fn guard(f: impl FnOnce() -> BridgeResult<()>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => std::ptr::null_mut(),
        Ok(Err(e)) => err_ptr(e),
        Err(_) => err_ptr("internal error (panic in bridge)"),
    }
}

unsafe fn cstr<'a>(p: *const c_char, what: &str) -> BridgeResult<&'a str> {
    if p.is_null() {
        return Err(format!("{what} is null"));
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| format!("{what} is not valid UTF-8"))
}

unsafe fn bytes<'a>(p: *const u8, len: usize, what: &str) -> BridgeResult<&'a [u8]> {
    if p.is_null() || len == 0 {
        return Err(format!("{what} is empty"));
    }
    Ok(unsafe { std::slice::from_raw_parts(p, len) })
}

fn runtime() -> BridgeResult<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("failed to start runtime: {e}"))
}

#[derive(Clone, Copy)]
pub(crate) struct Ctx(pub *mut c_void);
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

fn write_string_out(out: *mut *mut c_char, s: String) -> BridgeResult<()> {
    if out.is_null() {
        return Err("output pointer is null".into());
    }
    let c = CString::new(s).map_err(|_| "output contained NUL".to_string())?;
    unsafe { *out = c.into_raw() };
    Ok(())
}

/// Pair with an Apple TV that is showing "Remote App and Devices" pairing mode.
///
/// `host`/`port` should point at the `_remotepairing-manual-pairing._tcp`
/// service (the `_remotepairing._tcp` service also works on some versions).
/// `host_name` is how this iPhone is labelled on the TV.
///
/// On success `*out_file` / `*out_len` receive the pairing record; free it with
/// `atv_free_bytes`. `*out_peer_json` receives
/// `{"name", "model", "udid"}` describing the TV; free with `atv_free_string`.
///
/// # Safety
/// Pointers must be valid; `pin_cb` must be callable from this thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_pair(
    host: *const c_char,
    port: u16,
    host_name: *const c_char,
    pin_cb: AtvPinCallback,
    ctx: *mut c_void,
    out_file: *mut *mut u8,
    out_len: *mut usize,
    out_peer_json: *mut *mut c_char,
) -> *mut c_char {
    guard(|| {
        let host = unsafe { cstr(host, "host") }?;
        let host_name = unsafe { cstr(host_name, "host_name") }?;
        if out_file.is_null() || out_len.is_null() || out_peer_json.is_null() {
            return Err("output pointer is null".into());
        }
        let ctx = Ctx(ctx);
        let ep = Endpoint::new(host, port);

        let (rpf, peer) = runtime()?.block_on(session::pair(&ep, host_name, move || {
            let mut buf = vec![0 as c_char; 64];
            pin_cb(ctx.0, buf.as_mut_ptr(), buf.len());
            *buf.last_mut().unwrap() = 0;
            unsafe { CStr::from_ptr(buf.as_ptr()) }
                .to_string_lossy()
                .trim()
                .to_string()
        }))?;

        write_string_out(out_peer_json, peer)?;
        let mut data = rpf.to_bytes().into_boxed_slice();
        unsafe {
            *out_len = data.len();
            *out_file = data.as_mut_ptr();
        }
        std::mem::forget(data);
        Ok(())
    })
}

/// Connect with an existing pairing record and return device info as JSON:
/// `{"udid": ..., "name": ..., "productType": ..., "osVersion": ..., "buildVersion": ...}`.
///
/// `host`/`port` must point at the `_remotepairing._tcp` service.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_device_info(
    host: *const c_char,
    port: u16,
    host_name: *const c_char,
    pairing: *const u8,
    pairing_len: usize,
    out_json: *mut *mut c_char,
) -> *mut c_char {
    guard(|| {
        let host = unsafe { cstr(host, "host") }?;
        let host_name = unsafe { cstr(host_name, "host_name") }?;
        let rpf = parse_pairing(unsafe { bytes(pairing, pairing_len, "pairing record") }?)?;
        let ep = Endpoint::new(host, port);
        let json = runtime()?.block_on(async {
            let s = session::Session::open(&ep, host_name, rpf).await?;
            Ok::<_, String>(s.device_info_json())
        })?;
        write_string_out(out_json, json)
    })
}

/// Install a tvOS `.ipa` on the Apple TV. The IPA must already be signed so
/// the Apple TV accepts it (e.g. a development/ad-hoc profile containing the
/// TV's UDID).
///
/// # Safety
/// Pointers must be valid; `progress_cb` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_install(
    host: *const c_char,
    port: u16,
    host_name: *const c_char,
    pairing: *const u8,
    pairing_len: usize,
    ipa_path: *const c_char,
    progress_cb: Option<AtvProgressCallback>,
    ctx: *mut c_void,
) -> *mut c_char {
    guard(|| {
        let host = unsafe { cstr(host, "host") }?;
        let host_name = unsafe { cstr(host_name, "host_name") }?;
        let ipa_path = unsafe { cstr(ipa_path, "ipa_path") }?;
        let rpf = parse_pairing(unsafe { bytes(pairing, pairing_len, "pairing record") }?)?;
        let ep = Endpoint::new(host, port);
        let progress = session::Progress::new(progress_cb, Ctx(ctx));

        let info = ipa::inspect(std::path::Path::new(ipa_path))?;
        runtime()?.block_on(async {
            progress.report(0, 0, "Connecting to Apple TV");
            let mut s = session::Session::open(&ep, host_name, rpf).await?;
            s.install(std::path::Path::new(ipa_path), &info, &progress)
                .await
        })
    })
}

/// List user-installed apps as a JSON array of
/// `{"bundleId": ..., "name": ..., "version": ...}`.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_list_apps(
    host: *const c_char,
    port: u16,
    host_name: *const c_char,
    pairing: *const u8,
    pairing_len: usize,
    out_json: *mut *mut c_char,
) -> *mut c_char {
    guard(|| {
        let host = unsafe { cstr(host, "host") }?;
        let host_name = unsafe { cstr(host_name, "host_name") }?;
        let rpf = parse_pairing(unsafe { bytes(pairing, pairing_len, "pairing record") }?)?;
        let ep = Endpoint::new(host, port);
        let json = runtime()?.block_on(async {
            let mut s = session::Session::open(&ep, host_name, rpf).await?;
            s.list_apps().await
        })?;
        write_string_out(out_json, json)
    })
}

/// Uninstall an app by bundle identifier.
///
/// # Safety
/// Pointers must be valid; `progress_cb` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_uninstall(
    host: *const c_char,
    port: u16,
    host_name: *const c_char,
    pairing: *const u8,
    pairing_len: usize,
    bundle_id: *const c_char,
    progress_cb: Option<AtvProgressCallback>,
    ctx: *mut c_void,
) -> *mut c_char {
    guard(|| {
        let host = unsafe { cstr(host, "host") }?;
        let host_name = unsafe { cstr(host_name, "host_name") }?;
        let bundle_id = unsafe { cstr(bundle_id, "bundle_id") }?;
        let rpf = parse_pairing(unsafe { bytes(pairing, pairing_len, "pairing record") }?)?;
        let ep = Endpoint::new(host, port);
        let progress = session::Progress::new(progress_cb, Ctx(ctx));
        runtime()?.block_on(async {
            let mut s = session::Session::open(&ep, host_name, rpf).await?;
            s.uninstall(bundle_id, &progress).await
        })
    })
}

/// Read basic metadata from an IPA without contacting a device. Returns JSON
/// `{"bundleId", "name", "version", "platforms": [...], "isTvOS": bool}`.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_inspect_ipa(
    ipa_path: *const c_char,
    out_json: *mut *mut c_char,
) -> *mut c_char {
    guard(|| {
        let ipa_path = unsafe { cstr(ipa_path, "ipa_path") }?;
        let info = ipa::inspect(std::path::Path::new(ipa_path))?;
        write_string_out(out_json, info.to_json())
    })
}

/// Returns 1 if a `_remotepairing._tcp` Bonjour TXT record (`identifier` and
/// `authTag` values) was published by the Apple TV this pairing record belongs
/// to, 0 if not or if it can't be determined.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_service_matches(
    pairing: *const u8,
    pairing_len: usize,
    identifier: *const c_char,
    auth_tag: *const c_char,
) -> i32 {
    let res = catch_unwind(AssertUnwindSafe(|| -> BridgeResult<bool> {
        let rpf = parse_pairing(unsafe { bytes(pairing, pairing_len, "pairing record") }?)?;
        let identifier = unsafe { cstr(identifier, "identifier") }?;
        let auth_tag = unsafe { cstr(auth_tag, "auth_tag") }?;
        Ok(rpf.alt_irk().is_some_and(|irk| {
            idevice::remote_pairing::PeerDevice::validate_auth_tag(irk, identifier, auth_tag)
        }))
    }));
    matches!(res, Ok(Ok(true))) as i32
}

/// Ask `host` directly (unicast DNS-SD to port 5353) which RemotePairing
/// services it offers. Returns a JSON array of
/// `{"serviceType", "instance", "port"}`; empty if it didn't answer.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_probe_host(
    host: *const c_char,
    out_json: *mut *mut c_char,
) -> *mut c_char {
    guard(|| {
        let host = unsafe { cstr(host, "host") }?;
        let found = runtime()?.block_on(mdns_probe::probe(host))?;
        let list: Vec<serde_json::Value> = found
            .into_iter()
            .map(|f| {
                serde_json::json!({
                    "serviceType": f.service_type,
                    "instance": f.instance,
                    "port": f.port,
                })
            })
            .collect();
        write_string_out(out_json, serde_json::Value::Array(list).to_string())
    })
}

/// Free a string returned by any `atv_*` function.
///
/// # Safety
/// `s` must come from this library (or be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Free a buffer returned by `atv_pair`.
///
/// # Safety
/// `p`/`len` must come from `atv_pair` (or `p` be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atv_free_bytes(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)) });
    }
}

fn parse_pairing(b: &[u8]) -> BridgeResult<RpPairingFile> {
    RpPairingFile::from_bytes(b).map_err(|e| format!("invalid pairing record: {e}"))
}
