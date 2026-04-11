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
}

impl RateLimiter {
    pub fn new(max_requests: u32, window_secs: u64) -> Self {
        Self {
            entries: Arc::new(DashMap::new()),
            max_requests,
            window_secs,
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

/// Extract client IP from request headers or connection info.
///
/// Priority: X-Real-IP (set by trusted proxies) > X-Forwarded-For (last
/// non-private IP) > ConnectInfo > localhost.
///
/// **Security note**: X-Forwarded-For can be forged by clients.  We use the
/// LAST IP in the chain because Traefik *appends* the real client IP.  The
/// first IP is whatever the client sent and cannot be trusted.  X-Real-IP is
/// preferred because Traefik (when configured) sets it from the direct
/// connection.
fn extract_ip(req: &Request<Body>) -> IpAddr {
    // Prefer X-Real-IP (trusted, set by reverse proxy)
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

    // Fallback to ConnectInfo
    req.extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ci| ci.0.ip())
        .unwrap_or(IpAddr::V4(std::net::Ipv4Addr::LOCALHOST))
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
            let ip = extract_ip(&req);
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
pub fn login_limiter() -> RateLimiter {
    RateLimiter::new(5, 60)
}

/// Register rate limiter: 3 attempts per 60 seconds per IP.
pub fn register_limiter() -> RateLimiter {
    RateLimiter::new(3, 60)
}

/// Refresh token rate limiter: 10 attempts per 60 seconds per IP.
pub fn refresh_limiter() -> RateLimiter {
    RateLimiter::new(10, 60)
}

/// WebSocket ticket rate limiter: 10 tickets per 60 seconds per IP.
pub fn ticket_limiter() -> RateLimiter {
    RateLimiter::new(10, 60)
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
