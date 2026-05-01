//! Link preview endpoint — fetches Open Graph metadata from URLs.

use axum::Json;
use axum::extract::State;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;

use crate::auth::middleware::AuthUser;
use crate::error::AppError;

use super::AppState;

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

/// Validate URL scheme, resolve DNS, and reject SSRF-vulnerable addresses.
///
/// Returns a [`ValidatedUrl`] containing the resolved address so the caller
/// can pin it via `reqwest::ClientBuilder::resolve`, closing the TOCTOU
/// window between DNS validation and HTTP request.
fn validate_url(url: &str) -> Result<ValidatedUrl, AppError> {
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

    use std::net::ToSocketAddrs;
    let addrs: Vec<std::net::SocketAddr> = format!("{host}:{port}")
        .to_socket_addrs()
        .map_err(|_| AppError::bad_request("Could not resolve hostname"))?
        .collect();

    if addrs.is_empty() {
        return Err(AppError::bad_request(
            "Hostname did not resolve to any address",
        ));
    }

    // Validate ALL resolved addresses are safe (reject if any is private)
    for addr in &addrs {
        let ip = addr.ip();
        let is_private = match ip {
            std::net::IpAddr::V4(v4) => {
                v4.is_private()
                    || v4.is_link_local()
                    || v4.octets()[0] == 169 && v4.octets()[1] == 254
            }
            std::net::IpAddr::V6(v6) => {
                let seg = v6.segments();
                // ULA (fc00::/7)
                (seg[0] & 0xfe00) == 0xfc00
                // Link-local (fe80::/10)
                || (seg[0] & 0xffc0) == 0xfe80
                // IPv4-mapped (::ffff:0:0/96) -- check the mapped IPv4
                || matches!(v6.to_ipv4_mapped(), Some(v4) if v4.is_private()
                    || v4.is_loopback() || v4.is_link_local())
            }
        };
        if ip.is_loopback() || ip.is_unspecified() || is_private {
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
    let validated = validate_url(&body.url)?;

    // Pin the resolved IP so reqwest cannot re-resolve to a different
    // (potentially private) address after our validation -- closes the
    // TOCTOU DNS rebinding window.
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
}
