//! Push notification delivery for platforms that require it.
//!
//! **Android/Desktop**: No push needed. The client maintains a persistent
//! WebSocket connection (Android uses a foreground service to stay alive).
//!
//! **iOS**: Apple requires APNs to wake suspended apps. This module sends
//! visible notifications with sender info. For encrypted DMs, only the
//! sender name is shown ("Alice: Encrypted message"). For plaintext groups,
//! the actual message preview is included.
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

    let tokens = match db::push_tokens::get_tokens_for_users(pool, offline_user_ids).await {
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

/// Send an APNs push notification to an iOS device.
///
/// - **Encrypted DMs**: Shows "Encrypted message" as the body (server can't
///   read the ciphertext). The sender name is always visible.
/// - **Plaintext messages**: Shows a truncated preview of the actual content.
///
/// Also includes `content-available: 1` so the app wakes in the background
/// and reconnects the WebSocket to fetch the full message.
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

    let url = format!("https://api.push.apple.com/3/device/{}", p.device_token);

    // Encrypted DMs: server can't read content, show generic body.
    // Plaintext: show a truncated preview.
    let body = if p.is_encrypted {
        "Encrypted message".to_string()
    } else if p.content.len() > 140 {
        format!("{}...", &p.content[..140])
    } else {
        p.content.to_string()
    };

    let payload = serde_json::json!({
        "aps": {
            "alert": {
                "title": p.sender_username,
                "body": body,
            },
            "sound": "default",
            "badge": 1,
            "thread-id": p.conversation_id.to_string(),
            "content-available": 1,
        },
        "conversation_id": p.conversation_id.to_string(),
        "message_id": p.message_id.to_string(),
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
