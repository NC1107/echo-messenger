//! Push notification delivery for platforms that require it.
//!
//! **Android/Desktop**: No push needed. The client maintains a persistent
//! WebSocket connection (Android uses a foreground service to stay alive).
//!
//! **iOS**: Apple requires APNs to wake suspended apps. This module sends
//! visible notifications. For encrypted DMs, both the title and body are
//! redacted to "New message" so the lock screen leaks neither sender nor
//! content. For plaintext groups, the sender name and a truncated preview
//! of the message are included.
//!
//! ## Configuration (all optional — push is disabled if not set)
//!
//! - `APNS_AUTH_KEY_BASE64`: Base64-encoded `.p8` private key (preferred)
//! - `APNS_AUTH_KEY_PATH`: Path to `.p8` file on disk (alternative)
//! - `APNS_KEY_ID`: 10-character Key ID from Apple Developer portal
//! - `APNS_TEAM_ID`: 10-character Team ID from Apple Developer portal
//! - `APNS_TOPIC`: Bundle ID (e.g. `us.echomessenger.app`)
//!
//! Self-hosters: leave these unset and push is silently disabled. iOS users
//! will still receive messages when they open the app (WebSocket reconnect).

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use reqwest::Client;
use serde::Serialize;
use sqlx::PgPool;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::db;

// ---------------------------------------------------------------------------
// APNs configuration (loaded once at first use)
// ---------------------------------------------------------------------------

struct ApnsConfig {
    encoding_key: EncodingKey,
    key_id: String,
    team_id: String,
    topic: String,
    client: Client,
    /// Cached JWT token + its issue time (re-generated every 50 min).
    jwt_cache: RwLock<(String, u64)>,
}

static APNS: OnceLock<Option<ApnsConfig>> = OnceLock::new();

fn get_apns_config() -> &'static Option<ApnsConfig> {
    APNS.get_or_init(|| {
        let key_id = std::env::var("APNS_KEY_ID").ok()?;
        let team_id = std::env::var("APNS_TEAM_ID").ok()?;
        let topic = std::env::var("APNS_TOPIC")
            .ok()
            .unwrap_or_else(|| "us.echomessenger.app".to_string());

        // Load the .p8 key: prefer base64 env var, fall back to file path.
        let pem = if let Ok(b64) = std::env::var("APNS_AUTH_KEY_BASE64") {
            let raw = BASE64.decode(b64.trim()).ok()?;
            String::from_utf8(raw).ok()?
        } else if let Ok(path) = std::env::var("APNS_AUTH_KEY_PATH") {
            std::fs::read_to_string(&path).ok()?
        } else {
            tracing::info!("APNs disabled: no APNS_AUTH_KEY_BASE64 or APNS_AUTH_KEY_PATH set");
            return None;
        };

        let encoding_key = EncodingKey::from_ec_pem(pem.as_bytes()).ok()?;
        let client = Client::builder().http2_prior_knowledge().build().ok()?;

        tracing::info!("APNs push enabled (key_id={key_id}, team_id={team_id}, topic={topic})");
        Some(ApnsConfig {
            encoding_key,
            key_id,
            team_id,
            topic,
            client,
            jwt_cache: RwLock::new((String::new(), 0)),
        })
    })
}

/// Generate (or return cached) APNs JWT bearer token.
///
/// APNs tokens are valid for 1 hour; we regenerate every 50 minutes.
async fn get_apns_jwt(config: &ApnsConfig) -> Result<String, &'static str> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    // Check cache (read lock, fast path)
    {
        let cache = config.jwt_cache.read().await;
        if !cache.0.is_empty() && now - cache.1 < 3000 {
            return Ok(cache.0.clone());
        }
    }

    // Regenerate (write lock)
    let mut cache = config.jwt_cache.write().await;
    // Double-check after acquiring write lock
    if !cache.0.is_empty() && now - cache.1 < 3000 {
        return Ok(cache.0.clone());
    }

    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(config.key_id.clone());

    #[derive(Serialize)]
    struct Claims {
        iss: String,
        iat: u64,
    }

    let claims = Claims {
        iss: config.team_id.clone(),
        iat: now,
    };

    let token =
        encode(&header, &claims, &config.encoding_key).map_err(|_| "Failed to encode APNs JWT")?;

    *cache = (token.clone(), now);
    Ok(token)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Send push notifications to offline recipients who need them.
///
/// Called from the message fan-out path when `hub.send_to()` returns false.
/// Currently only sends to iOS devices (APNs). Android/desktop clients
/// maintain their own persistent connections.
///
/// Fire-and-forget -- errors are logged but don't affect message delivery.
pub async fn notify_offline_users(
    pool: &PgPool,
    offline_user_ids: &[Uuid],
    sender_username: &str,
    content: &str,
    is_encrypted: bool,
    conversation_id: Uuid,
    message_id: Uuid,
) {
    if offline_user_ids.is_empty() {
        return;
    }

    // Drop recipients who muted this conversation so they don't get an APNs
    // alert for messages they would not be notified about locally either.
    // Fail open on database errors -- it is better to over-notify than to
    // silently drop legitimate notifications.
    let unmuted =
        match db::messages::get_unmuted_user_ids(pool, conversation_id, offline_user_ids).await {
            Ok(u) => u,
            Err(e) => {
                tracing::warn!("Failed to filter muted users: {e}");
                offline_user_ids.to_vec()
            }
        };
    if unmuted.is_empty() {
        return;
    }

    let tokens = match db::push_tokens::get_tokens_for_users(pool, &unmuted).await {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!("Failed to fetch push tokens: {e}");
            return;
        }
    };

    if tokens.is_empty() {
        return;
    }

    let pool = pool.clone();
    for (user_id, token, platform) in &tokens {
        if platform.as_str() == "apns" {
            send_apns_push(ApnsPushParams {
                pool: &pool,
                user_id: *user_id,
                device_token: token,
                sender_username,
                content,
                is_encrypted,
                conversation_id,
                message_id,
            })
            .await;
        }
    }
}

struct ApnsPushParams<'a> {
    pool: &'a PgPool,
    user_id: Uuid,
    device_token: &'a str,
    sender_username: &'a str,
    content: &'a str,
    is_encrypted: bool,
    conversation_id: Uuid,
    message_id: Uuid,
}

/// Build the notification title.
///
/// For encrypted messages the sender username is redacted to a neutral
/// "New message" so a glanced-at lock screen does not leak who is messaging
/// whom. For plaintext (groups, unencrypted DMs) the sender name is shown
/// as-is.
fn format_push_title(sender_username: &str, is_encrypted: bool) -> String {
    if is_encrypted {
        "New message".to_string()
    } else {
        sender_username.to_string()
    }
}

/// Build the notification body text.
///
/// - Encrypted messages get a fixed placeholder (server can't read ciphertext).
/// - Plaintext longer than 140 bytes is truncated at a character boundary
///   to avoid slicing through a multi-byte UTF-8 sequence.
fn format_push_body(content: &str, is_encrypted: bool) -> String {
    const MAX_PREVIEW_BYTES: usize = 140;

    if is_encrypted {
        "New message".to_string()
    } else if content.len() > MAX_PREVIEW_BYTES {
        let end = content.floor_char_boundary(MAX_PREVIEW_BYTES);
        format!("{}...", &content[..end])
    } else {
        content.to_string()
    }
}

/// Send an APNs push notification to an iOS device.
///
/// - **Encrypted DMs**: Shows "New message" as both the title and body. The
///   sender name is redacted so lock-screen glances do not leak who is
///   messaging whom.
/// - **Plaintext messages**: Shows the sender name as the title and a
///   truncated preview of the actual content as the body.
///
/// Uses `mutable-content: 1` so a Notification Service Extension can modify
/// the payload before display.  Also includes `content-available: 1` to wake
/// the app for WebSocket reconnect.
async fn send_apns_push(p: ApnsPushParams<'_>) {
    let config = match get_apns_config() {
        Some(c) => c,
        None => return,
    };

    let jwt = match get_apns_jwt(config).await {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!("APNs JWT generation failed: {e}");
            return;
        }
    };

    let host = if std::env::var("APNS_SANDBOX").is_ok() {
        "api.sandbox.push.apple.com"
    } else {
        "api.push.apple.com"
    };
    let url = format!("https://{host}/3/device/{}", p.device_token);

    let body = format_push_body(p.content, p.is_encrypted);
    let title = format_push_title(p.sender_username, p.is_encrypted);

    let payload = serde_json::json!({
        "aps": {
            "alert": {
                "title": title,
                "body": body,
            },
            "sound": "default",
            "badge": 1,
            "thread-id": p.conversation_id.to_string(),
            "mutable-content": 1,
            "content-available": 1,
        },
        "conversation_id": p.conversation_id.to_string(),
        "message_id": p.message_id.to_string(),
        "sender_username": p.sender_username,
    });

    let result = config
        .client
        .post(&url)
        .header("authorization", format!("bearer {jwt}"))
        .header("apns-topic", &config.topic)
        .header("apns-push-type", "alert")
        .header("apns-priority", "10")
        .json(&payload)
        .send()
        .await;

    match result {
        Ok(resp) => {
            let status = resp.status().as_u16();
            match status {
                200 => {
                    tracing::debug!("APNs push sent to user {}", p.user_id);
                }
                410 => {
                    tracing::info!("APNs token invalid (410) for user {}, removing", p.user_id);
                    let _ = db::push_tokens::remove_token(p.pool, p.user_id, p.device_token).await;
                }
                _ => {
                    let err_body = resp.text().await.unwrap_or_default();
                    tracing::warn!(
                        "APNs push failed ({status}) for user {}: {err_body}",
                        p.user_id
                    );
                }
            }
        }
        Err(e) => {
            tracing::warn!("APNs HTTP request failed for user {}: {e}", p.user_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypted_message_returns_placeholder() {
        assert_eq!(format_push_body("secret stuff", true), "New message");
    }

    #[test]
    fn short_plaintext_returned_as_is() {
        assert_eq!(format_push_body("hello", false), "hello");
    }

    #[test]
    fn ascii_over_140_truncated_with_ellipsis() {
        let long = "a".repeat(200);
        let body = format_push_body(&long, false);
        assert!(body.ends_with("..."));
        // 140 chars of 'a' + "..."
        assert_eq!(body.len(), 143);
    }

    #[test]
    fn emoji_over_140_truncated_without_panic() {
        // Each emoji is 4 bytes; 36 emojis = 144 bytes (> 140).
        let emojis = "\u{1F600}".repeat(36);
        assert_eq!(emojis.len(), 144);
        let body = format_push_body(&emojis, false);
        assert!(body.ends_with("..."));
        // floor_char_boundary(140) for 4-byte chars = 140 -> lands at byte 140
        // which is the start of the 36th emoji, so we keep 35 emojis (140 bytes).
        assert_eq!(body, format!("{}...", "\u{1F600}".repeat(35)));
    }

    #[test]
    fn multibyte_boundary_mid_char_no_panic() {
        // "e\u{0301}" = 'e' (1 byte) + combining acute U+0301 (2 bytes) = 3 bytes per unit.
        // 47 units = 141 bytes (> 140). Byte 140 is 0x81, the continuation byte of the
        // 47th combining accent. floor_char_boundary(140) = 139, the start of that accent.
        let accent = "e\u{0301}".repeat(47); // 141 bytes
        assert_eq!(accent.len(), 141);
        let body = format_push_body(&accent, false);
        assert!(body.ends_with("..."));
        // 139 content bytes + 3 "..." = 142 bytes total.
        assert_eq!(body.len(), 142);
    }

    #[test]
    fn exactly_140_bytes_no_truncation() {
        let exact = "a".repeat(140);
        assert_eq!(format_push_body(&exact, false), exact);
    }

    #[test]
    fn exactly_141_bytes_truncated() {
        let over = "a".repeat(141);
        let body = format_push_body(&over, false);
        assert!(body.ends_with("..."));
        assert_eq!(body, format!("{}...", "a".repeat(140)));
    }

    #[test]
    fn empty_string_returned_as_is() {
        assert_eq!(format_push_body("", false), "");
    }

    #[test]
    fn encrypted_with_long_content_still_returns_placeholder() {
        assert_eq!(format_push_body(&"x".repeat(200), true), "New message");
    }

    #[test]
    fn encrypted_title_redacts_sender() {
        assert_eq!(format_push_title("alice", true), "New message");
    }

    #[test]
    fn plaintext_title_shows_sender() {
        assert_eq!(format_push_title("alice", false), "alice");
    }

    #[test]
    fn encrypted_title_redacts_even_long_sender() {
        let long_name = "a".repeat(200);
        assert_eq!(format_push_title(&long_name, true), "New message");
    }
}
