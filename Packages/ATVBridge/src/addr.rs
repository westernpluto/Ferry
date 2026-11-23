//! Turning the host strings the app passes in into socket addresses.
//!
//! iOS formats addresses from Bonjour with an interface suffix, e.g.
//! `192.168.1.130%en0` or `fe80::1%en0`. getaddrinfo rejects the suffix on IPv4
//! literals, so literals are parsed here and only names go to the resolver.

use std::net::{IpAddr, SocketAddr, SocketAddrV6};
use std::time::Duration;

use crate::BridgeResult;

const RESOLVE_TIMEOUT: Duration = Duration::from_secs(10);

/// Normalise what users / Bonjour hand us: trims whitespace, brackets and the
/// trailing dot of fully-qualified names.
pub fn clean_host(host: &str) -> String {
    host.trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .trim_end_matches('.')
        .to_string()
}

/// Parse an IP literal with an optional `%scope`. Returns `None` for names.
pub fn parse_literal(host: &str, port: u16) -> Option<SocketAddr> {
    let (ip, scope) = match host.split_once('%') {
        Some((ip, scope)) => (ip, Some(scope)),
        None => (host, None),
    };
    match ip.parse::<IpAddr>().ok()? {
        // An interface suffix means nothing for IPv4; drop it.
        IpAddr::V4(v4) => Some(SocketAddr::new(IpAddr::V4(v4), port)),
        IpAddr::V6(v6) => Some(SocketAddr::V6(SocketAddrV6::new(
            v6,
            port,
            0,
            scope.map(scope_id).unwrap_or(0),
        ))),
    }
}

fn scope_id(scope: &str) -> u32 {
    if let Ok(n) = scope.parse::<u32>() {
        return n;
    }
    interface_index(scope)
}

#[cfg(unix)]
fn interface_index(name: &str) -> u32 {
    let Ok(c) = std::ffi::CString::new(name) else {
        return 0;
    };
    unsafe extern "C" {
        fn if_nametoindex(ifname: *const std::ffi::c_char) -> u32;
    }
    unsafe { if_nametoindex(c.as_ptr()) }
}

#[cfg(not(unix))]
fn interface_index(_name: &str) -> u32 {
    0
}

/// Resolve `host:port` to one or more addresses, IPv4 first.
pub async fn resolve(host: &str, port: u16) -> BridgeResult<Vec<SocketAddr>> {
    let host = clean_host(host);
    if let Some(addr) = parse_literal(&host, port) {
        return Ok(vec![addr]);
    }
    let mut addrs: Vec<SocketAddr> = tokio::time::timeout(
        RESOLVE_TIMEOUT,
        tokio::net::lookup_host((host.as_str(), port)),
    )
    .await
    .map_err(|_| format!("timed out resolving {host}"))?
    .map_err(|e| format!("could not resolve {host}: {e}"))?
    .collect();
    addrs.sort_by_key(|a| a.is_ipv6());
    if addrs.is_empty() {
        return Err(format!("no addresses found for {host}"));
    }
    Ok(addrs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv6Addr;

    #[test]
    fn ipv4_with_interface_suffix() {
        let a = parse_literal(&clean_host("192.168.1.130%en0"), 49152).unwrap();
        assert_eq!(a, "192.168.1.130:49152".parse().unwrap());
    }

    #[test]
    fn ipv6_with_numeric_scope() {
        let a = parse_literal(&clean_host("[fe80::1%4]"), 80).unwrap();
        match a {
            SocketAddr::V6(v6) => {
                assert_eq!(v6.scope_id(), 4);
                assert_eq!(*v6.ip(), "fe80::1".parse::<Ipv6Addr>().unwrap());
            }
            _ => panic!("expected v6"),
        }
    }

    #[test]
    fn names_are_not_literals() {
        assert!(parse_literal(&clean_host("Living-Room.local."), 1).is_none());
        assert_eq!(clean_host(" Living-Room.local. "), "Living-Room.local");
    }

    #[tokio::test]
    async fn resolve_accepts_scoped_ipv4() {
        let a = resolve("192.168.1.130%en0", 5).await.unwrap();
        assert_eq!(a, vec!["192.168.1.130:5".parse().unwrap()]);
    }
}
