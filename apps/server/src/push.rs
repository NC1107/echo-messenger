//! Push notification delivery for platforms that require it.
//!
//! **Android/Desktop**: No push needed. The client maintains a persistent
//! WebSocket connection (Android uses a foreground service to stay alive).
//!
//! **iOS**: Apple requires APNs to wake suspended apps. This module sends
//! minimal silent pushes ("you have a new message") -- no message content
//! is ever sent through Apple's servers. The app wakes, reconnects the
//! WebSocket, and fetches messages directly from the Echo server.
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
    _sender_username: &str,
    _content: &str,
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
            send_apns_silent_push(&pool, *user_id, token, conversation_id, message_id).await;
        }
    }
}

/// Send a silent APNs push to wake the iOS app.
///
/// Uses a content-available push with no alert/body -- the app wakes in
/// the background, reconnects the WebSocket, and fetches the actual message
/// over the encrypted channel. No message content touches Apple's servers.
async fn send_apns_silent_push(
    pool: &PgPool,
    user_id: Uuid,
    device_token: &str,
    conversation_id: Uuid,
    message_id: Uuid,
) {
    let config = match get_apns_config() {
        Some(c) => c,
        None => return, // APNs not configured — silently skip
    };

    let jwt = match get_apns_jwt(config).await {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!("APNs JWT generation failed: {e}");
            return;
        }
    };

    let url = format!("https://api.push.apple.com/3/device/{device_token}");

    let payload = serde_json::json!({
        "aps": { "content-available": 1 },
        "conversation_id": conversation_id.to_string(),
        "message_id": message_id.to_string(),
    });

    let result = config
        .client
        .post(&url)
        .header("authorization", format!("bearer {jwt}"))
        .header("apns-topic", &config.topic)
        .header("apns-push-type", "background")
        .header("apns-priority", "5")
        .json(&payload)
        .send()
        .await;

    match result {
        Ok(resp) => {
            let status = resp.status().as_u16();
            match status {
                200 => {
                    tracing::debug!("APNs push sent to user {user_id}");
                }
                410 => {
                    // Token is no longer valid — remove it from DB
                    tracing::info!("APNs token invalid (410) for user {user_id}, removing");
                    let _ = db::push_tokens::remove_token(pool, user_id, device_token).await;
                }
                _ => {
                    let body = resp.text().await.unwrap_or_default();
                    tracing::warn!("APNs push failed ({status}) for user {user_id}: {body}");
                }
            }
        }
        Err(e) => {
            tracing::warn!("APNs HTTP request failed for user {user_id}: {e}");
        }
    }
}
