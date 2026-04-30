//! Simple in-memory rate limiting middleware for auth endpoints.

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{Request, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use dashmap::DashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Instant;

/// Tracks request count and window start per IP.
#[derive(Debug, Clone)]
struct RateBucket {
    count: u32,
    window_start: Instant,
}

/// Shared rate limit state using lock-free concurrent map.
#[derive(Debug, Clone)]
pub struct RateLimiter {
    entries: Arc<DashMap<IpAddr, RateBucket>>,
    max_requests: u32,
    window_secs: u64,
    /// IPs of reverse proxies whose `X-Real-IP` / `X-Forwarded-For`
    /// headers we trust.  When empty, proxy headers are ignored and the
    /// peer (ConnectInfo) IP is used directly.
    trusted_proxies: Arc<Vec<IpAddr>>,
}

impl RateLimiter {
    pub fn new(max_requests: u32, window_secs: u64) -> Self {
        Self {
            entries: Arc::new(DashMap::new()),
            max_requests,
            window_secs,
            trusted_proxies: Arc::new(Vec::new()),
        }
    }

    /// Create a rate limiter that honours proxy headers from `proxies`.
    pub fn with_trusted_proxies(max_requests: u32, window_secs: u64, proxies: Vec<IpAddr>) -> Self {
        Self {
            entries: Arc::new(DashMap::new()),
            max_requests,
            window_secs,
            trusted_proxies: Arc::new(proxies),
        }
    }

    /// Check rate limit for an IP. Returns true if the request should be allowed.
    fn check(&self, ip: IpAddr) -> bool {
        let now = Instant::now();

        // Opportunistic cleanup: remove entries older than 2x window
        let cleanup_threshold = self.window_secs * 2;
        self.entries.retain(|_, bucket| {
            now.duration_since(bucket.window_start).as_secs() < cleanup_threshold
        });

        let mut bucket = self.entries.entry(ip).or_insert(RateBucket {
            count: 0,
            window_start: now,
        });

        // Reset window if expired
        if now.duration_since(bucket.window_start).as_secs() >= self.window_secs {
            bucket.count = 0;
            bucket.window_start = now;
        }

        bucket.count += 1;
        bucket.count <= self.max_requests
    }
}

/// Get the peer (direct connection) IP from ConnectInfo.
fn peer_ip(req: &Request<Body>) -> IpAddr {
    req.extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ci| ci.0.ip())
        .unwrap_or(IpAddr::V4(std::net::Ipv4Addr::LOCALHOST))
}

/// Extract client IP from request, honouring proxy headers **only** when
/// the direct peer is in `trusted_proxies`.
///
/// When the peer is trusted:
///   X-Real-IP > X-Forwarded-For (last non-private) > peer IP
///
/// When the peer is NOT trusted (or `trusted_proxies` is empty):
///   peer IP is returned directly, proxy headers are ignored.
///
/// **Security note**: X-Forwarded-For can be forged by clients.  We use
/// the LAST IP in the chain because Traefik *appends* the real client IP.
/// The first IP is whatever the client sent and cannot be trusted.
fn extract_ip(req: &Request<Body>, trusted_proxies: &[IpAddr]) -> IpAddr {
    let direct = peer_ip(req);

    // Only honour proxy headers when the immediate peer is a trusted proxy
    if trusted_proxies.is_empty() || !trusted_proxies.contains(&direct) {
        return direct;
    }

    // Prefer X-Real-IP (set by trusted reverse proxy)
    if let Some(xri) = req.headers().get("x-real-ip")
        && let Ok(value) = xri.to_str()
        && let Ok(ip) = value.trim().parse::<IpAddr>()
    {
        return ip;
    }

    // Fallback to X-Forwarded-For -- use the LAST IP (appended by our proxy),
    // not the first (attacker-controlled).  Reject private/loopback IPs to
    // prevent spoofing bypass.
    if let Some(xff) = req.headers().get("x-forwarded-for")
        && let Ok(value) = xff.to_str()
        && let Some(last_ip) = value.rsplit(',').next()
        && let Ok(ip) = last_ip.trim().parse::<IpAddr>()
        && !ip.is_loopback()
        && !ip.is_unspecified()
        && !is_private(ip)
    {
        return ip;
    }

    // Peer is trusted but headers are absent/invalid -- use peer IP
    direct
}

/// Create a rate-limit middleware layer function for a given limiter.
/// The limiter is cloned into the closure.
pub fn make_rate_limit_layer(
    limiter: RateLimiter,
) -> impl Fn(
    Request<Body>,
    Next,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Response> + Send>>
+ Clone
+ Send {
    move |req: Request<Body>, next: Next| {
        let limiter = limiter.clone();
        Box::pin(async move {
            let ip = extract_ip(&req, &limiter.trusted_proxies);
            if !limiter.check(ip) {
                return (
                    StatusCode::TOO_MANY_REQUESTS,
                    axum::Json(
                        serde_json::json!({ "error": "Too many requests. Please try again later." }),
                    ),
                )
                    .into_response();
            }
            next.run(req).await
        })
    }
}

/// Login rate limiter: 5 attempts per 60 seconds per IP.
pub fn login_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(5, 60, trusted_proxies)
}

/// Register rate limiter: 3 attempts per 60 seconds per IP.
pub fn register_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(3, 60, trusted_proxies)
}

/// Refresh token rate limiter: 10 attempts per 60 seconds per IP.
pub fn refresh_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(10, 60, trusted_proxies)
}

/// WebSocket ticket rate limiter: 10 tickets per 60 seconds per IP.
pub fn ticket_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(10, 60, trusted_proxies)
}

/// Media upload rate limiter: 30 uploads per 60 seconds per IP.
pub fn media_upload_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(30, 60, trusted_proxies)
}

/// Link preview rate limiter: 20 requests per 60 seconds per IP.
pub fn link_preview_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(20, 60, trusted_proxies)
}

/// Key reset rate limiter: 3 attempts per 300 seconds per IP.
/// Tight limit since this is a password-guessing vector.
pub fn key_reset_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(3, 300, trusted_proxies)
}

/// Revoke-others rate limiter: 3 requests per 60 seconds per IP.
/// Revoking every other device is a disruptive op -- cap it tightly so
/// stolen tokens can't wipe a user's whole device list in a loop.
pub fn revoke_others_limiter(trusted_proxies: Vec<IpAddr>) -> RateLimiter {
    RateLimiter::with_trusted_proxies(3, 60, trusted_proxies)
}

/// Check whether an IP is in a private/reserved range (RFC 1918, link-local, ULA).
fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            // ULA: fc00::/7 (first byte 0xFC or 0xFD)
            let first_segment = v6.segments()[0];
            let is_ula = (first_segment & 0xfe00) == 0xfc00;
            // Link-local: fe80::/10
            let is_link_local = (first_segment & 0xffc0) == 0xfe80;
            is_ula || is_link_local
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn test_allows_within_limit() {
        let limiter = RateLimiter::new(3, 60);
        let ip = IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4));
        assert!(limiter.check(ip));
        assert!(limiter.check(ip));
        assert!(limiter.check(ip));
    }

    #[test]
    fn test_blocks_over_limit() {
        let limiter = RateLimiter::new(2, 60);
        let ip = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1));
        assert!(limiter.check(ip)); // 1
        assert!(limiter.check(ip)); // 2
        assert!(!limiter.check(ip)); // 3 -> blocked
        assert!(!limiter.check(ip)); // still blocked
    }

    #[test]
    fn test_different_ips_independent() {
        let limiter = RateLimiter::new(1, 60);
        let ip_a = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));
        let ip_b = IpAddr::V4(Ipv4Addr::new(2, 2, 2, 2));
        assert!(limiter.check(ip_a));
        assert!(!limiter.check(ip_a)); // blocked
        assert!(limiter.check(ip_b)); // different IP, allowed
    }

    #[test]
    fn test_login_limiter_config() {
        let limiter = login_limiter(vec![]);
        assert_eq!(limiter.max_requests, 5);
        assert_eq!(limiter.window_secs, 60);
    }

    #[test]
    fn test_register_limiter_config() {
        let limiter = register_limiter(vec![]);
        assert_eq!(limiter.max_requests, 3);
        assert_eq!(limiter.window_secs, 60);
    }

    #[test]
    fn test_media_upload_limiter_config() {
        let limiter = media_upload_limiter(vec![]);
        assert_eq!(limiter.max_requests, 30);
        assert_eq!(limiter.window_secs, 60);
    }

    #[test]
    fn test_link_preview_limiter_config() {
        let limiter = link_preview_limiter(vec![]);
        assert_eq!(limiter.max_requests, 20);
        assert_eq!(limiter.window_secs, 60);
    }

    #[test]
    fn test_is_private_ipv4() {
        assert!(is_private(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))));
        assert!(is_private(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))));
        assert!(is_private(IpAddr::V4(Ipv4Addr::new(172, 16, 0, 1))));
        assert!(is_private(IpAddr::V4(Ipv4Addr::new(169, 254, 1, 1)))); // link-local
        assert!(!is_private(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8))));
    }

    #[test]
    fn test_is_private_ipv6_ula() {
        // ULA: fc00::/7
        assert!(is_private(IpAddr::V6(Ipv6Addr::new(
            0xfc00, 0, 0, 0, 0, 0, 0, 1
        ))));
        assert!(is_private(IpAddr::V6(Ipv6Addr::new(
            0xfd12, 0x3456, 0, 0, 0, 0, 0, 1
        ))));
        // Link-local: fe80::/10
        assert!(is_private(IpAddr::V6(Ipv6Addr::new(
            0xfe80, 0, 0, 0, 0, 0, 0, 1
        ))));
        // Public IPv6
        assert!(!is_private(IpAddr::V6(Ipv6Addr::new(
            0x2001, 0xdb8, 0, 0, 0, 0, 0, 1
        ))));
    }

    /// Helper: build a request with ConnectInfo set to the given address.
    fn req_with_peer(peer: SocketAddr) -> Request<Body> {
        let mut req = Request::new(Body::empty());
        req.extensions_mut().insert(ConnectInfo(peer));
        req
    }

    #[test]
    fn test_proxy_headers_ignored_without_trusted_proxies() {
        // No trusted proxies -> X-Real-IP header is ignored
        let peer: SocketAddr = "10.0.0.1:1234".parse().unwrap();
        let mut req = req_with_peer(peer);
        req.headers_mut()
            .insert("x-real-ip", "1.2.3.4".parse().unwrap());
        let ip = extract_ip(&req, &[]);
        // Should return the peer IP, not the spoofed header
        assert_eq!(ip, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)));
    }

    #[test]
    fn test_proxy_headers_ignored_from_untrusted_peer() {
        let trusted = vec![IpAddr::V4(Ipv4Addr::new(172, 17, 0, 1))];
        // Peer is NOT the trusted proxy
        let peer: SocketAddr = "203.0.113.99:1234".parse().unwrap();
        let mut req = req_with_peer(peer);
        req.headers_mut()
            .insert("x-real-ip", "1.2.3.4".parse().unwrap());
        let ip = extract_ip(&req, &trusted);
        assert_eq!(
            ip,
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 99)),
            "untrusted peer's X-Real-IP should be ignored"
        );
    }

    #[test]
    fn test_x_real_ip_honoured_from_trusted_proxy() {
        let proxy_ip = IpAddr::V4(Ipv4Addr::new(172, 17, 0, 1));
        let trusted = vec![proxy_ip];
        let peer: SocketAddr = "172.17.0.1:1234".parse().unwrap();
        let mut req = req_with_peer(peer);
        req.headers_mut()
            .insert("x-real-ip", "1.2.3.4".parse().unwrap());
        let ip = extract_ip(&req, &trusted);
        assert_eq!(
            ip,
            IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4)),
            "trusted proxy's X-Real-IP should be used"
        );
    }

    #[test]
    fn test_xff_honoured_from_trusted_proxy() {
        let proxy_ip = IpAddr::V4(Ipv4Addr::new(172, 17, 0, 1));
        let trusted = vec![proxy_ip];
        let peer: SocketAddr = "172.17.0.1:1234".parse().unwrap();
        let mut req = req_with_peer(peer);
        req.headers_mut()
            .insert("x-forwarded-for", "spoofed, 203.0.113.50".parse().unwrap());
        let ip = extract_ip(&req, &trusted);
        assert_eq!(ip, IpAddr::V4(Ipv4Addr::new(203, 0, 113, 50)));
    }

    #[test]
    fn test_xff_private_ip_rejected_even_from_trusted_proxy() {
        let proxy_ip = IpAddr::V4(Ipv4Addr::new(172, 17, 0, 1));
        let trusted = vec![proxy_ip];
        let peer: SocketAddr = "172.17.0.1:1234".parse().unwrap();
        let mut req = req_with_peer(peer);
        req.headers_mut()
            .insert("x-forwarded-for", "1.2.3.4, 192.168.1.1".parse().unwrap());
        // Last IP is private -> should fall through to peer IP
        let ip = extract_ip(&req, &trusted);
        assert_eq!(
            ip,
            IpAddr::V4(Ipv4Addr::new(172, 17, 0, 1)),
            "private XFF IP should be rejected"
        );
    }

    #[test]
    fn test_x_real_ip_preferred_over_xff_from_trusted_proxy() {
        let proxy_ip = IpAddr::V4(Ipv4Addr::new(172, 17, 0, 1));
        let trusted = vec![proxy_ip];
        let peer: SocketAddr = "172.17.0.1:1234".parse().unwrap();
        let mut req = req_with_peer(peer);
        req.headers_mut()
            .insert("x-real-ip", "1.2.3.4".parse().unwrap());
        req.headers_mut()
            .insert("x-forwarded-for", "5.6.7.8".parse().unwrap());
        let ip = extract_ip(&req, &trusted);
        assert_eq!(ip, IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4)));
    }

    #[test]
    fn test_with_trusted_proxies_constructor() {
        let proxies = vec![IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))];
        let limiter = RateLimiter::with_trusted_proxies(5, 60, proxies.clone());
        assert_eq!(limiter.max_requests, 5);
        assert_eq!(limiter.window_secs, 60);
        assert_eq!(*limiter.trusted_proxies, proxies);
    }
}
