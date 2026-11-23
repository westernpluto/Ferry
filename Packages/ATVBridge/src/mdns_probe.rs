//! Ask a specific host for its RemotePairing services with a unicast DNS-SD
//! query to port 5353 (RFC 6762 §6.7 "legacy unicast"). This finds the port
//! when the user only knows the Apple TV's IP address, and works even on
//! networks that block multicast.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::UdpSocket;

use crate::BridgeResult;

pub const SERVICE_TYPES: [&str; 2] = [
    "_remotepairing._tcp.local",
    "_remotepairing-manual-pairing._tcp.local",
];

const TYPE_PTR: u16 = 12;
const TYPE_SRV: u16 = 33;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoundService {
    pub service_type: String,
    pub instance: String,
    pub port: u16,
}

pub async fn probe(host: &str) -> BridgeResult<Vec<FoundService>> {
    let addr: SocketAddr = crate::addr::resolve(host, 5353).await?[0];
    let bind: SocketAddr = if addr.is_ipv4() {
        "0.0.0.0:0".parse().unwrap()
    } else {
        "[::]:0".parse().unwrap()
    };
    let sock = UdpSocket::bind(bind)
        .await
        .map_err(|e| format!("could not open UDP socket: {e}"))?;

    let query = build_query(0x1A7B, &SERVICE_TYPES, TYPE_PTR);
    let mut found: Vec<FoundService> = Vec::new();
    let mut buf = vec![0u8; 9000];

    // A few attempts; responders may drop the first packet while waking.
    for _ in 0..3 {
        sock.send_to(&query, addr)
            .await
            .map_err(|e| format!("could not reach {host}: {e}"))?;
        let deadline = tokio::time::Instant::now() + Duration::from_millis(1200);
        loop {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            if left.is_zero() {
                break;
            }
            match tokio::time::timeout(left, sock.recv_from(&mut buf)).await {
                Ok(Ok((n, _))) => {
                    for s in parse_response(&buf[..n]) {
                        if !found.contains(&s) {
                            found.push(s);
                        }
                    }
                }
                _ => break,
            }
        }
        if !found.is_empty() {
            break;
        }
    }

    Ok(found)
}

fn encode_name(out: &mut Vec<u8>, name: &str) {
    for label in name.trim_end_matches('.').split('.') {
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
}

pub fn build_query(id: u16, names: &[&str], qtype: u16) -> Vec<u8> {
    let mut q = Vec::new();
    q.extend_from_slice(&id.to_be_bytes());
    q.extend_from_slice(&0u16.to_be_bytes()); // flags: standard query
    q.extend_from_slice(&(names.len() as u16).to_be_bytes());
    q.extend_from_slice(&[0, 0, 0, 0, 0, 0]); // an/ns/ar
    for n in names {
        encode_name(&mut q, n);
        q.extend_from_slice(&qtype.to_be_bytes());
        q.extend_from_slice(&1u16.to_be_bytes()); // IN
    }
    q
}

/// Reads a (possibly compressed) DNS name starting at `pos`. Returns the name and
/// the offset just past it in the original stream.
fn read_name(msg: &[u8], mut pos: usize) -> Option<(String, usize)> {
    let mut labels: Vec<String> = Vec::new();
    let mut end: Option<usize> = None;
    let mut jumps = 0;
    loop {
        let len = *msg.get(pos)? as usize;
        if len == 0 {
            pos += 1;
            break;
        }
        if len & 0xC0 == 0xC0 {
            let ptr = ((len & 0x3F) << 8) | *msg.get(pos + 1)? as usize;
            if end.is_none() {
                end = Some(pos + 2);
            }
            jumps += 1;
            if jumps > 32 {
                return None;
            }
            pos = ptr;
            continue;
        }
        let label = msg.get(pos + 1..pos + 1 + len)?;
        labels.push(String::from_utf8_lossy(label).into_owned());
        pos += 1 + len;
    }
    Some((labels.join("."), end.unwrap_or(pos)))
}

fn u16_at(msg: &[u8], pos: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*msg.get(pos)?, *msg.get(pos + 1)?]))
}

pub fn parse_response(msg: &[u8]) -> Vec<FoundService> {
    parse_inner(msg).unwrap_or_default()
}

fn parse_inner(msg: &[u8]) -> Option<Vec<FoundService>> {
    let qd = u16_at(msg, 4)? as usize;
    let rr = u16_at(msg, 6)? as usize + u16_at(msg, 8)? as usize + u16_at(msg, 10)? as usize;
    let mut pos = 12;
    for _ in 0..qd {
        let (_, p) = read_name(msg, pos)?;
        pos = p + 4;
    }

    // instance full name -> service type, and instance full name -> port
    let mut ptrs: Vec<(String, String)> = Vec::new();
    let mut srvs: HashMap<String, u16> = HashMap::new();
    for _ in 0..rr {
        let (name, p) = read_name(msg, pos)?;
        let rtype = u16_at(msg, p)?;
        let rdlen = u16_at(msg, p + 8)? as usize;
        let rdata = p + 10;
        match rtype {
            TYPE_PTR => {
                let (target, _) = read_name(msg, rdata)?;
                ptrs.push((name.to_lowercase(), target));
            }
            TYPE_SRV => {
                let port = u16_at(msg, rdata + 4)?;
                srvs.insert(name.to_lowercase(), port);
            }
            _ => {}
        }
        pos = rdata + rdlen;
    }

    let mut out = Vec::new();
    for (service_type, instance_full) in ptrs {
        let Some(&port) = srvs.get(&instance_full.to_lowercase()) else {
            continue;
        };
        let suffix = format!(".{service_type}");
        let instance = if instance_full.to_lowercase().ends_with(&suffix) {
            instance_full[..instance_full.len() - suffix.len()].to_string()
        } else {
            instance_full.clone()
        };
        out.push(FoundService {
            service_type: service_type.trim_end_matches(".local").to_string(),
            instance,
            port,
        });
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a response the way mDNSResponder does: PTR answer, SRV additional,
    /// with name compression.
    fn sample_response() -> Vec<u8> {
        let mut m = Vec::new();
        m.extend_from_slice(&[0x1A, 0x7B, 0x84, 0x00, 0, 0, 0, 1, 0, 0, 0, 1]);
        // answer: _remotepairing._tcp.local PTR "Living Room._remotepairing._tcp.local"
        let type_off = m.len();
        encode_name(&mut m, "_remotepairing._tcp.local");
        m.extend_from_slice(&TYPE_PTR.to_be_bytes());
        m.extend_from_slice(&1u16.to_be_bytes());
        m.extend_from_slice(&120u32.to_be_bytes());
        let mut rdata = vec![11];
        rdata.extend_from_slice(b"Living Room");
        rdata.extend_from_slice(&[0xC0 | (type_off >> 8) as u8, type_off as u8]);
        m.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        let inst_off = m.len();
        m.extend_from_slice(&rdata);
        // additional: SRV for the instance (compressed name)
        m.extend_from_slice(&[0xC0 | (inst_off >> 8) as u8, inst_off as u8]);
        m.extend_from_slice(&TYPE_SRV.to_be_bytes());
        m.extend_from_slice(&0x8001u16.to_be_bytes());
        m.extend_from_slice(&120u32.to_be_bytes());
        let mut srv = vec![0, 0, 0, 0];
        srv.extend_from_slice(&49234u16.to_be_bytes());
        encode_name(&mut srv, "Living-Room.local");
        m.extend_from_slice(&(srv.len() as u16).to_be_bytes());
        m.extend_from_slice(&srv);
        m
    }

    #[test]
    fn parses_ptr_and_srv() {
        let found = parse_response(&sample_response());
        assert_eq!(
            found,
            vec![FoundService {
                service_type: "_remotepairing._tcp".into(),
                instance: "Living Room".into(),
                port: 49234,
            }]
        );
    }

    #[test]
    fn query_is_well_formed() {
        let q = build_query(1, &SERVICE_TYPES, TYPE_PTR);
        assert_eq!(u16_at(&q, 4), Some(2));
        let (name, p) = read_name(&q, 12).unwrap();
        assert_eq!(name, "_remotepairing._tcp.local");
        assert_eq!(u16_at(&q, p), Some(TYPE_PTR));
    }

    #[test]
    fn garbage_does_not_panic() {
        assert!(parse_response(&[1, 2, 3]).is_empty());
        let mut bad = sample_response();
        bad.truncate(40);
        let _ = parse_response(&bad);
    }
}
