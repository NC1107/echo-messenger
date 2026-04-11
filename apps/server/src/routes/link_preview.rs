//! Link preview endpoint — fetches Open Graph metadata from URLs.

use axum::Json;
use axum::extract::State;
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

/// POST /api/link-preview
///
/// Fetches Open Graph metadata from a URL. Requires authentication.
/// Returns title, description, image, and site name if available.
pub async fn fetch_preview(
    _auth: AuthUser,
    _state: State<Arc<AppState>>,
    Json(body): Json<LinkPreviewRequest>,
) -> Result<Json<LinkPreviewResponse>, AppError> {
    // Basic URL validation
    if !body.url.starts_with("http://") && !body.url.starts_with("https://") {
        return Err(AppError::bad_request(
            "URL must start with http:// or https://",
        ));
    }

    // SSRF protection: resolve hostname and reject private/loopback IPs
    if let Ok(url) = reqwest::Url::parse(&body.url)
        && let Some(host) = url.host_str()
    {
        use std::net::ToSocketAddrs;
        let port = url.port_or_known_default().unwrap_or(80);
        if let Ok(addrs) = format!("{host}:{port}").to_socket_addrs() {
            for addr in addrs {
                let ip = addr.ip();
                if ip.is_loopback()
                    || ip.is_unspecified()
                    || matches!(ip, std::net::IpAddr::V4(v4) if v4.is_private()
                            || v4.is_link_local()
                            || v4.octets()[0] == 169 && v4.octets()[1] == 254)
                {
                    return Err(AppError::bad_request(
                        "URL resolves to a private or reserved address",
                    ));
                }
            }
        }
    }

    // Fetch the page with a short timeout
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()
        .map_err(|_| AppError::internal("Failed to create HTTP client"))?;

    let resp = client
        .get(&body.url)
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

    // Limit body size to 256KB to prevent abuse
    let html = resp
        .text()
        .await
        .map_err(|_| AppError::bad_request("Failed to read response"))?;
    let html = if html.len() > 262_144 {
        &html[..262_144]
    } else {
        &html
    };

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
