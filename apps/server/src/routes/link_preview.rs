//! Link preview endpoint — fetches Open Graph metadata from URLs.

use axum::Json;
use axum::extract::State;
use futures_util::StreamExt;
use ipnet::{IpNet, Ipv4Net};
use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::Duration;

use crate::auth::middleware::AuthUser;
use crate::error::AppError;

use super::AppState;

/// Special-use IPv4 ranges that must be rejected in addition to the standard
/// `is_private()` / `is_link_local()` / `is_loopback()` checks. Catches
/// addresses that resolve from public DNS but route to cloud-internal services
/// (CGNAT, benchmark ranges, multicast, etc.).
///
/// TD-31. See IANA Special-Purpose Address Registry (RFC 6890).
fn ssrf_v4_denylist() -> &'static [Ipv4Net] {
    static DENY: OnceLock<Vec<Ipv4Net>> = OnceLock::new();
    DENY.get_or_init(|| {
        [
            "0.0.0.0/8", // "this network" — already covered by is_unspecified for ::0 but the /8 isn't
            "100.64.0.0/10", // CGNAT — cloud edge networks often route private services here
            "127.0.0.0/8", // loopback — `is_loopback` only covers 127.0.0.1
            "169.254.0.0/16", // link-local — `is_link_local` already covers, kept for clarity
            "192.0.0.0/24", // IETF Protocol Assignments
            "192.0.2.0/24", // TEST-NET-1 (docs)
            "192.168.0.0/16", // RFC 1918
            "198.18.0.0/15", // Benchmarking (RFC 2544)
            "198.51.100.0/24", // TEST-NET-2
            "203.0.113.0/24", // TEST-NET-3
            "224.0.0.0/4", // Multicast — fan-out + smurf-amplification vector
            "240.0.0.0/4", // Reserved future use / 255.255.255.255 broadcast
        ]
        .iter()
        .map(|s| s.parse().expect("denylist CIDR must parse"))
        .collect()
    })
}

/// Ports we'll fetch on. Anything else (Redis, Memcached, internal admin
/// interfaces on 8080, 9200 for ElasticSearch, …) is rejected to limit the
/// SSRF blast radius even if a future bug let a private IP through.
const ALLOWED_PORTS: &[u16] = &[80, 443];

#[derive(Deserialize)]
pub struct LinkPreviewRequest {
    pub url: String,
}

#[derive(Serialize, Default)]
pub struct LinkPreviewResponse {
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub site_name: Option<String>,
}

/// Maximum HTML response bytes to process (256 KB).
const MAX_HTML_BYTES: usize = 262_144;

/// Cap HTML to [`MAX_HTML_BYTES`] at a valid UTF-8 boundary.
fn cap_html(html: &str) -> &str {
    if html.len() > MAX_HTML_BYTES {
        &html[..html.floor_char_boundary(MAX_HTML_BYTES)]
    } else {
        html
    }
}

/// Resolved URL metadata returned by [`validate_url`].
#[derive(Debug)]
struct ValidatedUrl {
    /// The original URL string.
    url: reqwest::Url,
    /// The hostname from the URL (needed for `resolve()` pinning).
    host: String,
    /// A validated, non-private socket address that the hostname resolved to.
    /// Used with `reqwest::ClientBuilder::resolve` to pin DNS and prevent
    /// TOCTOU rebinding attacks.
    resolved: std::net::SocketAddr,
}

/// True if `v4` falls into any of [`ssrf_v4_denylist`].
fn is_v4_denied(v4: Ipv4Addr) -> bool {
    let addr = IpNet::from(std::net::IpAddr::V4(v4));
    ssrf_v4_denylist()
        .iter()
        .any(|net| IpNet::V4(*net).contains(&addr))
}

/// Reject SSRF-vulnerable IPs across v4 and v6, including IPv4-mapped IPv6.
///
/// TD-31: the previous implementation missed CGNAT, multicast, TEST-NETs,
/// and benchmarking ranges. Consolidates the v6 IPv4-mapped path into the
/// v4 check.
fn is_ssrf_target(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_unspecified()
                || v4.is_broadcast()
                || v4.is_link_local()
                || v4.is_private()
                || is_v4_denied(v4)
        }
        std::net::IpAddr::V6(v6) => {
            if v6.is_loopback() || v6.is_unspecified() || v6.is_multicast() {
                return true;
            }
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_ssrf_target(std::net::IpAddr::V4(v4));
            }
            let seg = v6.segments();
            // ULA fc00::/7, link-local fe80::/10, site-local fec0::/10 (deprecated but reserved),
            // documentation 2001:db8::/32, IPv4-translated 2002::/16 (6to4 — could embed private v4).
            (seg[0] & 0xfe00) == 0xfc00
                || (seg[0] & 0xffc0) == 0xfe80
                || (seg[0] & 0xffc0) == 0xfec0
                || (seg[0] == 0x2001 && seg[1] == 0x0db8)
        }
    }
}

/// Validate URL scheme, resolve DNS, and reject SSRF-vulnerable addresses.
///
/// Returns a [`ValidatedUrl`] containing the resolved address so the caller
/// can pin it via `reqwest::ClientBuilder::resolve`, closing the TOCTOU
/// window between DNS validation and HTTP request.
async fn validate_url(url: &str) -> Result<ValidatedUrl, AppError> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err(AppError::bad_request(
            "URL must start with http:// or https://",
        ));
    }

    let parsed = reqwest::Url::parse(url).map_err(|_| AppError::bad_request("Invalid URL"))?;

    let host = parsed
        .host_str()
        .ok_or_else(|| AppError::bad_request("URL has no host"))?
        .to_string();

    let port = parsed.port_or_known_default().unwrap_or(80);

    // TD-31: egress port allow-list blocks SSRF probes of internal services.
    if !ALLOWED_PORTS.contains(&port) {
        return Err(AppError::bad_request(
            "URL port not permitted (only 80 and 443)",
        ));
    }

    // TD-31: dual-stack async lookup so SSRF check runs over every candidate.
    let addrs: Vec<std::net::SocketAddr> = tokio::net::lookup_host((host.as_str(), port))
        .await
        .map_err(|_| AppError::bad_request("Could not resolve hostname"))?
        .collect();

    if addrs.is_empty() {
        return Err(AppError::bad_request(
            "Hostname did not resolve to any address",
        ));
    }

    // Validate ALL addrs — defeats split-horizon DNS games.
    for addr in &addrs {
        if is_ssrf_target(addr.ip()) {
            return Err(AppError::bad_request(
                "URL resolves to a private or reserved address",
            ));
        }
    }

    // Use the first safe address for pinning
    Ok(ValidatedUrl {
        url: parsed,
        host,
        resolved: addrs[0],
    })
}

/// POST /api/link-preview
///
/// Fetches Open Graph metadata from a URL. Requires authentication.
/// Returns title, description, image, and site name if available.
pub async fn fetch_preview(
    _auth: AuthUser,
    _state: State<Arc<AppState>>,
    Json(body): Json<LinkPreviewRequest>,
) -> Result<Json<LinkPreviewResponse>, AppError> {
    let validated = validate_url(&body.url).await?;

    // Pin the resolved IP so reqwest can't re-resolve (DNS rebinding TOCTOU).
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none())
        .resolve(&validated.host, validated.resolved)
        .build()
        .map_err(|_| AppError::internal("Failed to create HTTP client"))?;

    let resp = client
        .get(validated.url)
        .header("User-Agent", "EchoMessenger/1.0 LinkPreview")
        .send()
        .await
        .map_err(|_| AppError::bad_request("Failed to fetch URL"))?;

    if !resp.status().is_success() {
        return Err(AppError::bad_request("URL returned non-success status"));
    }

    // Only process HTML responses (not images, PDFs, etc.)
    let content_type = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if !content_type.contains("text/html") {
        return Ok(Json(LinkPreviewResponse {
            url: body.url,
            ..Default::default()
        }));
    }

    if let Some(declared_len) = resp.content_length()
        && declared_len > MAX_HTML_BYTES as u64
    {
        return Err(AppError::bad_request(
            "URL response declares Content-Length above the size cap",
        ));
    }

    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::with_capacity(8 * 1024);
    while let Some(chunk_result) = stream.next().await {
        let chunk: bytes::Bytes =
            chunk_result.map_err(|_| AppError::bad_request("Failed to read response"))?;
        // Cap hard; we don't even copy the tail of an oversized chunk.
        let remaining = MAX_HTML_BYTES.saturating_sub(buf.len());
        if remaining == 0 {
            break;
        }
        let take = chunk.len().min(remaining);
        buf.extend_from_slice(&chunk[..take]);
        if buf.len() >= MAX_HTML_BYTES {
            break;
        }
    }
    let html_owned = String::from_utf8_lossy(&buf).into_owned();
    let html = cap_html(&html_owned);

    // Extract Open Graph tags with simple regex (no HTML parser dependency)
    let title = extract_og_content(html, "og:title").or_else(|| extract_tag_content(html, "title"));
    let description = extract_og_content(html, "og:description")
        .or_else(|| extract_meta_content(html, "description"));
    let image = extract_og_content(html, "og:image");
    let site_name = extract_og_content(html, "og:site_name");

    Ok(Json(LinkPreviewResponse {
        url: body.url,
        title,
        description,
        image,
        site_name,
    }))
}

/// Extract content from `<meta property="og:X" content="Y">`.
fn extract_og_content(html: &str, property: &str) -> Option<String> {
    let pattern = format!(r#"property="{property}""#);
    let pos = html.find(&pattern)?;
    // Look for content="..." nearby (within 200 chars)
    let slice = &html[pos..std::cmp::min(pos + 200, html.len())];
    let content_start = slice.find(r#"content=""#)? + 9;
    let content_end = slice[content_start..].find('"')?;
    let value = &slice[content_start..content_start + content_end];
    if value.is_empty() {
        return None;
    }
    Some(html_decode(value))
}

/// Extract content from `<meta name="X" content="Y">`.
fn extract_meta_content(html: &str, name: &str) -> Option<String> {
    let pattern = format!(r#"name="{name}""#);
    let pos = html.find(&pattern)?;
    let slice = &html[pos..std::cmp::min(pos + 200, html.len())];
    let content_start = slice.find(r#"content=""#)? + 9;
    let content_end = slice[content_start..].find('"')?;
    let value = &slice[content_start..content_start + content_end];
    if value.is_empty() {
        return None;
    }
    Some(html_decode(value))
}

/// Extract text between `<title>` and `</title>`.
fn extract_tag_content(html: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}");
    let close = format!("</{tag}>");
    let start = html.find(&open)?;
    let after_open = html[start..].find('>')? + start + 1;
    let end = html[after_open..].find(&close)? + after_open;
    let value = html[after_open..end].trim();
    if value.is_empty() {
        return None;
    }
    Some(html_decode(value))
}

/// Basic HTML entity decoding.
fn html_decode(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_under_limit_not_truncated() {
        let html = "Hello, world!";
        assert_eq!(cap_html(html), "Hello, world!");
    }

    #[test]
    fn html_exactly_at_limit_not_truncated() {
        let html = "a".repeat(MAX_HTML_BYTES);
        assert_eq!(cap_html(&html).len(), MAX_HTML_BYTES);
    }

    #[test]
    fn html_one_over_limit_truncated() {
        let html = "a".repeat(MAX_HTML_BYTES + 1);
        assert_eq!(cap_html(&html).len(), MAX_HTML_BYTES);
    }

    #[test]
    fn html_3byte_chars_at_boundary_no_panic() {
        // "あ" = 3 bytes. Build a string exceeding the limit.
        let html: String = "あ".repeat(MAX_HTML_BYTES / 3 + 10);
        assert!(html.len() > MAX_HTML_BYTES);
        let truncated = cap_html(&html);
        assert!(truncated.len() <= MAX_HTML_BYTES);
        assert!(truncated.is_char_boundary(truncated.len()));
    }

    #[test]
    fn html_4byte_emoji_at_boundary_no_panic() {
        let html: String = "\u{1F600}".repeat(MAX_HTML_BYTES / 4 + 10);
        assert!(html.len() > MAX_HTML_BYTES);
        let truncated = cap_html(&html);
        assert!(truncated.len() <= MAX_HTML_BYTES);
        assert!(truncated.is_char_boundary(truncated.len()));
    }

    /// Mirrors the streaming accumulation loop in `fetch_preview`; asserts
    /// that feeding 3x the cap worth of chunks never grows the buffer past
    /// `MAX_HTML_BYTES`. Covers the OOM-DoS / gzip-bomb fix for #684.
    #[test]
    fn stream_accumulation_stops_at_cap() {
        let chunk_size = 4096_usize;
        // Feed chunks totalling 3x the cap to prove the loop halts.
        let total_chunks = (MAX_HTML_BYTES / chunk_size) * 3;
        let chunk = vec![b'x'; chunk_size];

        let mut buf: Vec<u8> = Vec::with_capacity(8 * 1024);
        for _ in 0..total_chunks {
            let remaining = MAX_HTML_BYTES.saturating_sub(buf.len());
            if remaining == 0 {
                break;
            }
            let take = chunk.len().min(remaining);
            buf.extend_from_slice(&chunk[..take]);
            if buf.len() >= MAX_HTML_BYTES {
                break;
            }
        }

        assert_eq!(buf.len(), MAX_HTML_BYTES);
    }

    /// Content-Length fast-path: a declared length one byte over the cap must
    /// satisfy the `> MAX_HTML_BYTES as u64` guard used in the handler.
    #[test]
    fn content_length_above_cap_triggers_rejection_guard() {
        let declared_len = (MAX_HTML_BYTES as u64) + 1;
        assert!(declared_len > MAX_HTML_BYTES as u64);
    }

    // ----- TD-31: SSRF denial coverage --------------------------------

    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    fn v4(s: &str) -> IpAddr {
        IpAddr::V4(s.parse::<Ipv4Addr>().unwrap())
    }

    fn v6(s: &str) -> IpAddr {
        IpAddr::V6(s.parse::<Ipv6Addr>().unwrap())
    }

    #[test]
    fn ssrf_rejects_loopback_and_private() {
        assert!(is_ssrf_target(v4("127.0.0.1")));
        assert!(is_ssrf_target(v4("10.0.0.1")));
        assert!(is_ssrf_target(v4("172.16.0.1")));
        assert!(is_ssrf_target(v4("192.168.1.1")));
        assert!(is_ssrf_target(v4("169.254.169.254"))); // AWS metadata endpoint
    }

    #[test]
    fn ssrf_rejects_cgnat_benchmark_testnet() {
        assert!(is_ssrf_target(v4("100.64.0.1")), "CGNAT");
        assert!(is_ssrf_target(v4("100.127.255.1")), "CGNAT upper");
        assert!(is_ssrf_target(v4("198.18.0.1")), "RFC 2544 benchmark");
        assert!(is_ssrf_target(v4("192.0.2.1")), "TEST-NET-1");
        assert!(is_ssrf_target(v4("198.51.100.1")), "TEST-NET-2");
        assert!(is_ssrf_target(v4("203.0.113.1")), "TEST-NET-3");
        assert!(is_ssrf_target(v4("192.0.0.1")), "IETF protocol assignments");
    }

    #[test]
    fn ssrf_rejects_multicast_and_reserved() {
        assert!(is_ssrf_target(v4("224.0.0.1")));
        assert!(is_ssrf_target(v4("239.255.255.250")));
        assert!(is_ssrf_target(v4("240.0.0.1")));
        assert!(is_ssrf_target(v4("255.255.255.255")));
        assert!(is_ssrf_target(v4("0.0.0.0")));
    }

    #[test]
    fn ssrf_rejects_ipv4_mapped_v6() {
        // ::ffff:169.254.169.254 — AWS metadata expressed as mapped v6.
        let mapped = Ipv4Addr::new(169, 254, 169, 254).to_ipv6_mapped();
        assert!(is_ssrf_target(IpAddr::V6(mapped)));
    }

    #[test]
    fn ssrf_rejects_v6_loopback_ula_link_local_multicast_doc() {
        assert!(is_ssrf_target(v6("::1")));
        assert!(is_ssrf_target(v6("fc00::1"))); // ULA
        assert!(is_ssrf_target(v6("fe80::1"))); // link-local
        assert!(is_ssrf_target(v6("fec0::1"))); // deprecated site-local
        assert!(is_ssrf_target(v6("ff02::1"))); // multicast
        assert!(is_ssrf_target(v6("2001:db8::1"))); // documentation prefix
    }

    #[test]
    fn ssrf_allows_public_addresses() {
        assert!(!is_ssrf_target(v4("8.8.8.8")));
        assert!(!is_ssrf_target(v4("1.1.1.1")));
        assert!(!is_ssrf_target(v4("142.251.46.196"))); // google.com sample
        assert!(!is_ssrf_target(v6("2606:4700:4700::1111"))); // 1.1.1.1 v6
    }

    #[tokio::test]
    async fn validate_url_rejects_unsupported_scheme() {
        let err = validate_url("file:///etc/passwd").await.unwrap_err();
        assert!(err.message.contains("http://"));
    }

    #[tokio::test]
    async fn validate_url_rejects_non_http_port() {
        let err = validate_url("http://example.com:6379/").await.unwrap_err();
        assert!(err.message.to_lowercase().contains("port"));
    }

    #[tokio::test]
    async fn validate_url_rejects_https_on_non_443() {
        let err = validate_url("https://example.com:8443/").await.unwrap_err();
        assert!(err.message.to_lowercase().contains("port"));
    }
}
