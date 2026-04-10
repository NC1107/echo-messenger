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
//! Requires `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_AUTH_KEY_PATH` env
//! vars for iOS push. If not set, iOS push is silently skipped.

use sqlx::PgPool;
use uuid::Uuid;

use crate::db;

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

    for (_user_id, token, platform) in &tokens {
        if platform.as_str() == "apns" {
            send_apns_silent_push(token, conversation_id, message_id).await;
        }
    }
}

/// Send a silent APNs push to wake the iOS app.
///
/// Uses a content-available push with no alert/body -- the app wakes in
/// the background, reconnects the WebSocket, and fetches the actual message
/// over the encrypted channel. No message content touches Apple's servers.
async fn send_apns_silent_push(device_token: &str, conversation_id: Uuid, message_id: Uuid) {
    // APNs requires:
    // - An Apple Developer account with push notification capability
    // - A .p8 auth key file (APNS_AUTH_KEY_PATH env var)
    // - Key ID (APNS_KEY_ID) and Team ID (APNS_TEAM_ID)
    // - HTTP/2 client to api.push.apple.com
    //
    // The payload is a silent push (content-available: 1, no alert):
    // {
    //   "aps": { "content-available": 1 },
    //   "conversation_id": "...",
    //   "message_id": "..."
    // }
    //
    // TODO: Implement when iOS app is ready for TestFlight with push entitlement.
    // For now, the iOS app reconnects when returning to foreground.
    let _ = (device_token, conversation_id, message_id);
    tracing::debug!("APNs silent push not yet implemented (awaiting push entitlement)");
}
