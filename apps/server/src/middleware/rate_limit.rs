//! Simple in-memory rate limiting middleware for auth endpoints.

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{Request, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::Mutex;

/// Tracks request count and window start per IP.
#[derive(Debug, Clone)]
struct RateBucket {
    count: u32,
    window_start: Instant,
}

/// Shared rate limit state.
#[derive(Debug, Clone)]
pub struct RateLimiter {
    entries: Arc<Mutex<HashMap<IpAddr, RateBucket>>>,
    max_requests: u32,
    window_secs: u64,
}

impl RateLimiter {
    pub fn new(max_requests: u32, window_secs: u64) -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
            max_requests,
            window_secs,
        }
    }

    /// Check rate limit for an IP. Returns true if the request should be allowed.
    async fn check(&self, ip: IpAddr) -> bool {
        let now = Instant::now();
        let mut entries = self.entries.lock().await;

        // Opportunistic cleanup: remove entries older than 2x window
        let cleanup_threshold = self.window_secs * 2;
        entries.retain(|_, bucket| {
            now.duration_since(bucket.window_start).as_secs() < cleanup_threshold
        });

        let bucket = entries.entry(ip).or_insert(RateBucket {
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

/// Extract client IP from ConnectInfo or return a loopback fallback.
fn extract_ip(req: &Request<Body>) -> IpAddr {
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
            if !limiter.check(ip).await {
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
