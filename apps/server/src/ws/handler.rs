//! WebSocket message handling and routing.

use axum::extract::ws::{Message as WsMessage, WebSocket};
use chrono::{DateTime, Utc};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;
use crate::ws::message_service;
use crate::ws::typing_service;

#[derive(Deserialize)]
#[serde(tag = "type")]
enum ClientMessage {
    #[serde(rename = "send_message")]
    SendMessage {
        conversation_id: Option<Uuid>,
        channel_id: Option<Uuid>,
        to_user_id: Option<Uuid>,
        content: String,
        reply_to_id: Option<Uuid>,
        /// Recipient-scoped per-device ciphertexts:
        /// `recipient_user_id (UUID string) -> { device_id (i32 string) -> base64 ciphertext }`.
        /// JSON object keys are strings on the wire; conversion to typed
        /// `(Uuid, i32)` happens at the storage and fanout boundaries. Recipient
        /// scoping is required because per-user device IDs collide across users (#522).
        #[serde(default)]
        recipient_device_contents: Option<HashMap<String, HashMap<String, String>>>,
        /// Optional TTL in seconds. When Some, overrides the conversation-level
        /// disappearing-messages setting for this specific message.
        #[serde(default)]
        ttl_seconds: Option<i64>,
    },
    #[serde(rename = "typing")]
    Typing {
        conversation_id: Uuid,
        channel_id: Option<Uuid>,
    },
    #[serde(rename = "read_receipt")]
    ReadReceipt { conversation_id: Uuid },
    #[serde(rename = "voice_signal")]
    VoiceSignal {
        conversation_id: Uuid,
        channel_id: Uuid,
        to_user_id: Uuid,
        signal: serde_json::Value,
    },
    #[serde(rename = "key_reset")]
    KeyReset { conversation_id: Uuid },
    #[serde(rename = "call_started")]
    CallStarted { conversation_id: Uuid },
    /// Voice-lounge canvas event.  Relayed to all conversation members and
    /// persisted for strokes/images (avatar moves are ephemeral).
    ///
    /// `kind` is one of: "stroke", "clear", "image_add", "image_move",
    ///                    "image_remove", "avatar_move"
    #[serde(rename = "canvas_event")]
    CanvasEvent {
        channel_id: Uuid,
        kind: String,
        payload: serde_json::Value,
    },
}

#[derive(Serialize, Clone)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "new_message")]
    NewMessage {
        message_id: Uuid,
        from_user_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        from_device_id: Option<i32>,
        from_username: String,
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        content: String,
        timestamp: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_id: Option<Uuid>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_username: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        expires_at: Option<DateTime<Utc>>,
        /// Set to `true` when the server cannot deliver per-device ciphertext
        /// for this recipient (e.g. offline-replay where the message predates
        /// multi-device fanout, or no row exists for this device). The client
        /// should render an undecryptable placeholder rather than attempting
        /// to decrypt foreign ciphertext (#557).
        #[serde(skip_serializing_if = "Option::is_none")]
        undecryptable: Option<bool>,
    },
    /// Sent to the sender's OTHER devices so they see outgoing messages.
    #[serde(rename = "self_message")]
    SelfMessage {
        message_id: Uuid,
        from_device_id: i32,
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        content: String,
        timestamp: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_id: Option<Uuid>,
    },
    #[serde(rename = "message_sent")]
    MessageSent {
        message_id: Uuid,
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        timestamp: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        expires_at: Option<DateTime<Utc>>,
    },
    #[serde(rename = "delivered")]
    Delivered {
        message_id: Uuid,
        conversation_id: Uuid,
    },
    #[serde(rename = "typing")]
    Typing {
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        user_id: Uuid,
        from_username: String,
    },
    #[serde(rename = "read_receipt")]
    ReadReceipt {
        conversation_id: Uuid,
        user_id: Uuid,
    },
    #[serde(rename = "error")]
    Error { message: String },
    #[serde(rename = "voice_signal")]
    VoiceSignal {
        conversation_id: Uuid,
        channel_id: Uuid,
        from_user_id: Uuid,
        signal: serde_json::Value,
    },
    #[serde(rename = "key_reset")]
    KeyReset {
        from_user_id: Uuid,
        from_username: String,
        conversation_id: Uuid,
    },
    #[serde(rename = "call_started")]
    CallStarted {
        from_user_id: Uuid,
        from_username: String,
        conversation_id: Uuid,
    },
    /// Sent to all conversation members when a disappearing message is deleted.
    #[serde(rename = "message_expired")]
    MessageExpired {
        message_id: Uuid,
        conversation_id: Uuid,
    },
    /// Sent to all sessions of a user when one of their devices is revoked.
    /// The receiving client should log out if `device_id` matches its own.
    #[serde(rename = "device_revoked")]
    DeviceRevoked { device_id: i32 },
    /// Voice-lounge canvas event relayed to all conversation members.
    #[serde(rename = "canvas_event")]
    CanvasEvent {
        channel_id: Uuid,
        from_user_id: Uuid,
        kind: String,
        payload: serde_json::Value,
    },
}

pub async fn handle_socket(
    socket: WebSocket,
    user_id: Uuid,
    device_id: i32,
    username: String,
    state: Arc<AppState>,
) {
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::channel::<WsMessage>(256);

    // Register in hub (multi-device: keyed by user_id + device_id)
    state.hub.register(user_id, device_id, tx);

    // Broadcast online presence to contacts
    typing_service::broadcast_presence(&state, user_id, &username, "online").await;

    // Forward hub messages to WebSocket sink. Audit #696: previously this
    // ran as a detached `tokio::spawn` and the receive loop ran serially
    // afterward, so the two halves had no shared lifecycle -- if the peer's
    // TCP died but more inbound bytes arrived, the receive loop kept
    // accepting frames and the hub kept enqueueing into a now-unread mpsc
    // channel until it filled. Conversely if the receive loop ended first
    // (ticket expiry), aborting the send task discarded any pending hub
    // messages. We now wrap both halves in `tokio::select!` so either half
    // ending tears down both, and we drain `rx` with a brief timeout after
    // shutdown to flush in-flight frames before the connection drops.
    let send_fut = async move {
        while let Some(msg) = rx.recv().await {
            if sender.send(msg).await.is_err() {
                break;
            }
        }
        // Return ownership of the sink + the receiver so the post-shutdown
        // drain step can continue using the same socket.
        (sender, rx)
    };
    tokio::pin!(send_fut);

    // Task: send heartbeat every 30 seconds to keep the connection alive
    // through reverse-proxy (Traefik/Cloudflare) idle timeouts.
    //
    // We send BOTH a WebSocket protocol Ping (for proxy keepalive) and an
    // application-level JSON heartbeat. Browser WebSocket APIs handle
    // Ping/Pong transparently without surfacing them to JavaScript, so the
    // client's heartbeat monitor would never see protocol Pings.  The JSON
    // heartbeat triggers the browser's onMessage callback, letting the
    // client know the connection is still alive.
    let ping_hub = state.hub.clone();
    let ping_user_id = user_id;
    let ping_device_id = device_id;
    let ping_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        // The first tick fires immediately; skip it.
        interval.tick().await;
        loop {
            interval.tick().await;
            // Protocol-level Ping (proxy keepalive; invisible to browsers).
            ping_hub.send_to_device(
                &ping_user_id,
                ping_device_id,
                WsMessage::Ping(vec![].into()),
            );
            // Application-level heartbeat (visible to all clients).
            let hb = r#"{"type":"heartbeat"}"#.to_string();
            if !ping_hub.send_to_device(&ping_user_id, ping_device_id, WsMessage::Text(hb.into())) {
                break;
            }
        }
    });

    // Update device last_seen so the management UI reflects recent activity.
    // Fire-and-forget: the connection must not block on a DB write here.
    {
        let pool = state.pool.clone();
        tokio::spawn(async move {
            if let Err(e) = db::keys::update_last_seen(&pool, user_id, device_id).await {
                tracing::warn!(
                    "update_last_seen failed for user {user_id} device {device_id}: {e}"
                );
            }
        });
    }

    message_service::deliver_undelivered_messages(&state, user_id, device_id).await;

    // Run receive + send concurrently. Whichever finishes first triggers the
    // tear-down; the other half is awaited (or dropped) in the cleanup arm.
    let recv_fut = run_receive_loop(&mut receiver, user_id, device_id, &username, &state);
    tokio::pin!(recv_fut);

    let leftover_rx: Option<mpsc::Receiver<WsMessage>> = tokio::select! {
        _ = &mut recv_fut => {
            // Receive loop ended -- the send half might still have pending
            // frames in `rx`. Unregister so no new ones land, then attempt a
            // brief drain (50ms) to flush what's already buffered.
            state.hub.unregister(user_id, device_id);
            // Pull the sink + rx back out of the send future by polling
            // it once with a tight timeout. If the channel was already
            // closed by `unregister` (which dropped the tx) the future
            // resolves immediately; otherwise the timeout caps it.
            match tokio::time::timeout(Duration::from_millis(50), &mut send_fut).await {
                Ok((_sender, rx)) => Some(rx),
                Err(_) => None,
            }
        }
        (_sender, rx) = &mut send_fut => {
            // Send half ended (peer TCP died, or rx was closed). Stop
            // accepting new inbound frames by unregistering, then let the
            // recv future complete naturally as the underlying socket
            // surfaces the error.
            state.hub.unregister(user_id, device_id);
            // Best-effort: give the recv loop a moment to observe the
            // socket close before we drop it.
            let _ = tokio::time::timeout(Duration::from_millis(50), &mut recv_fut).await;
            Some(rx)
        }
    };
    drop(leftover_rx);
    ping_task.abort();

    cleanup_user_voice_sessions(&state, user_id).await;

    // Broadcast offline presence to contacts
    typing_service::broadcast_presence(&state, user_id, &username, "offline").await;

    tracing::info!("WebSocket disconnected: {} ({})", username, user_id);
}

/// Rate-limited WebSocket receive loop.
///
/// Uses a token bucket algorithm: 30 messages per 10-second window
/// (refill rate = 3 tokens/sec, burst cap = 30). A byte-rate bucket
/// caps throughput at 100 KB/s to prevent bandwidth abuse. After 3
/// consecutive rate-limit violations the connection is closed.
async fn run_receive_loop(
    receiver: &mut futures_util::stream::SplitStream<WebSocket>,
    user_id: Uuid,
    device_id: i32,
    username: &str,
    state: &AppState,
) {
    /// Tokens added per second (30 messages / 10 seconds).
    const REFILL_RATE: f64 = 3.0;
    /// Maximum tokens the bucket can hold (== window size).
    const BUCKET_CAPACITY: f64 = 30.0;
    /// Maximum payload size for a single message (64 KB).
    const MAX_MESSAGE_BYTES: usize = 64 * 1024;
    /// Byte-rate bucket capacity (100 KB).
    const BYTE_BUCKET_CAPACITY: f64 = 100.0 * 1024.0;
    /// Byte-rate refill (100 KB/s).
    const BYTE_REFILL_RATE: f64 = 100.0 * 1024.0;
    /// Consecutive violations before forced disconnect.
    const MAX_CONSECUTIVE_VIOLATIONS: u32 = 3;

    let mut tokens: f64 = BUCKET_CAPACITY;
    let mut byte_tokens: f64 = BYTE_BUCKET_CAPACITY;
    let mut last_refill = Instant::now();
    let mut consecutive_violations: u32 = 0;

    while let Some(Ok(msg)) = receiver.next().await {
        // Refill tokens based on elapsed time.
        let now = Instant::now();
        let elapsed = now.duration_since(last_refill).as_secs_f64();
        tokens = (tokens + elapsed * REFILL_RATE).min(BUCKET_CAPACITY);
        byte_tokens = (byte_tokens + elapsed * BYTE_REFILL_RATE).min(BYTE_BUCKET_CAPACITY);
        last_refill = now;

        match msg {
            WsMessage::Text(text) => {
                let msg_len = text.len();

                // Reject oversized messages immediately.
                if msg_len > MAX_MESSAGE_BYTES {
                    tracing::warn!(
                        user_id = %user_id,
                        username = %username,
                        bytes = msg_len,
                        "WebSocket message exceeds size limit, dropping"
                    );
                    send_error(state, user_id, "Message too large (max 64 KB)");
                    consecutive_violations += 1;
                    if consecutive_violations >= MAX_CONSECUTIVE_VIOLATIONS {
                        tracing::warn!(
                            user_id = %user_id,
                            "Disconnecting after {} consecutive violations",
                            consecutive_violations
                        );
                        send_error(state, user_id, "Too many violations, disconnecting");
                        break;
                    }
                    continue;
                }

                // Check message-rate bucket.
                if tokens < 1.0 {
                    tracing::warn!(
                        user_id = %user_id,
                        username = %username,
                        "WebSocket rate limit exceeded, dropping message"
                    );
                    send_error(state, user_id, "Rate limit exceeded, please slow down");
                    consecutive_violations += 1;
                    if consecutive_violations >= MAX_CONSECUTIVE_VIOLATIONS {
                        tracing::warn!(
                            user_id = %user_id,
                            "Disconnecting after {} consecutive violations",
                            consecutive_violations
                        );
                        send_error(state, user_id, "Too many violations, disconnecting");
                        break;
                    }
                    continue;
                }

                // Check byte-rate bucket.
                let cost = msg_len as f64;
                if byte_tokens < cost {
                    tracing::warn!(
                        user_id = %user_id,
                        username = %username,
                        "WebSocket byte-rate limit exceeded, dropping message"
                    );
                    send_error(state, user_id, "Byte-rate limit exceeded, please slow down");
                    consecutive_violations += 1;
                    if consecutive_violations >= MAX_CONSECUTIVE_VIOLATIONS {
                        tracing::warn!(
                            user_id = %user_id,
                            "Disconnecting after {} consecutive violations",
                            consecutive_violations
                        );
                        send_error(state, user_id, "Too many violations, disconnecting");
                        break;
                    }
                    continue;
                }

                tokens -= 1.0;
                byte_tokens -= cost;
                consecutive_violations = 0;
                handle_text_message(&text, user_id, device_id, username, state).await;
            }
            WsMessage::Close(_) => break,
            // Binary/Ping/Pong frames: count bytes toward the rate limit to
            // prevent abuse via non-text frames.
            other => {
                let cost = match &other {
                    WsMessage::Binary(b) => b.len() as f64,
                    WsMessage::Ping(b) | WsMessage::Pong(b) => b.len() as f64,
                    _ => 0.0,
                };
                if cost > 0.0 {
                    if byte_tokens < cost {
                        consecutive_violations += 1;
                        if consecutive_violations >= MAX_CONSECUTIVE_VIOLATIONS {
                            break;
                        }
                        continue;
                    }
                    byte_tokens -= cost;
                    consecutive_violations = 0;
                }
            }
        }
    }
}

/// Clean up stale voice sessions for a disconnecting user and broadcast
/// leave events to group members.
async fn cleanup_user_voice_sessions(state: &AppState, user_id: Uuid) {
    let removed_sessions =
        match db::channels::leave_all_user_voice_sessions(&state.pool, user_id).await {
            Ok(sessions) => sessions,
            Err(_) => return,
        };

    for (channel_id, conversation_id) in removed_sessions {
        let member_ids = typing_service::get_member_ids_cached(&state.pool, conversation_id).await;
        if let Ok(member_ids) = member_ids {
            let event = serde_json::json!({
                "type": "voice_session_left",
                "group_id": conversation_id,
                "channel_id": channel_id,
                "user_id": user_id,
            });
            if let Ok(json) = serde_json::to_string(&event) {
                state.hub.broadcast_json(&member_ids, &json, None);
            }
        }
    }
}

/// Maximum WebSocket text frame size (64 KB).  Frames larger than this are
/// rejected before JSON parsing to prevent memory exhaustion from oversized
/// payloads.  Legitimate messages are well under this limit (max message
/// content is 10 KB, and the JSON envelope adds minimal overhead).
const MAX_WS_FRAME_BYTES: usize = 65_536;

async fn handle_text_message(
    text: &str,
    sender_id: Uuid,
    sender_device_id: i32,
    sender_username: &str,
    state: &AppState,
) {
    if text.len() > MAX_WS_FRAME_BYTES {
        send_error(
            state,
            sender_id,
            &format!(
                "Message too large ({} bytes, max {})",
                text.len(),
                MAX_WS_FRAME_BYTES
            ),
        );
        return;
    }

    let msg: ClientMessage = match serde_json::from_str(text) {
        Ok(m) => m,
        Err(e) => {
            send_error(state, sender_id, &format!("Invalid message: {}", e));
            return;
        }
    };

    match msg {
        ClientMessage::SendMessage {
            conversation_id,
            channel_id,
            to_user_id,
            content,
            reply_to_id,
            recipient_device_contents,
            ttl_seconds,
        } => {
            message_service::handle_send_message(
                state,
                sender_id,
                sender_device_id,
                sender_username,
                conversation_id,
                channel_id,
                to_user_id,
                content,
                reply_to_id,
                recipient_device_contents,
                ttl_seconds,
            )
            .await;
        }
        ClientMessage::Typing {
            conversation_id,
            channel_id,
        } => {
            typing_service::handle_typing(
                state,
                sender_id,
                sender_username,
                conversation_id,
                channel_id,
            )
            .await;
        }
        ClientMessage::ReadReceipt { conversation_id } => {
            typing_service::handle_read_receipt(state, sender_id, conversation_id).await;
        }
        ClientMessage::VoiceSignal {
            conversation_id,
            channel_id,
            to_user_id,
            signal,
        } => {
            handle_voice_signal(
                state,
                sender_id,
                conversation_id,
                channel_id,
                to_user_id,
                signal,
            )
            .await;
        }
        ClientMessage::KeyReset { conversation_id } => {
            handle_broadcast_event(
                state,
                sender_id,
                sender_username,
                conversation_id,
                |from_user_id, from_username, conversation_id| ServerMessage::KeyReset {
                    from_user_id,
                    from_username,
                    conversation_id,
                },
            )
            .await;
        }
        ClientMessage::CallStarted { conversation_id } => {
            handle_broadcast_event(
                state,
                sender_id,
                sender_username,
                conversation_id,
                |from_user_id, from_username, conversation_id| ServerMessage::CallStarted {
                    from_user_id,
                    from_username,
                    conversation_id,
                },
            )
            .await;
        }
        ClientMessage::CanvasEvent {
            channel_id,
            kind,
            payload,
        } => {
            handle_canvas_event(state, sender_id, channel_id, kind, payload).await;
        }
    }
}

/// Generic handler for simple broadcast events (key_reset, call_started, etc.).
/// Verifies membership, then broadcasts to all conversation members except sender.
async fn handle_broadcast_event<F>(
    state: &AppState,
    sender_id: Uuid,
    sender_username: &str,
    conversation_id: Uuid,
    build_event: F,
) where
    F: FnOnce(Uuid, String, Uuid) -> ServerMessage,
{
    if !typing_service::check_membership_cached(&state.pool, conversation_id, sender_id).await {
        return;
    }

    let member_ids = match typing_service::get_member_ids_cached(&state.pool, conversation_id).await
    {
        Ok(ids) => ids,
        Err(_) => return,
    };

    let event = build_event(sender_id, sender_username.to_string(), conversation_id);
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .broadcast_json(&member_ids, &json, Some(sender_id));
    }
}

async fn handle_voice_signal(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Uuid,
    channel_id: Uuid,
    to_user_id: Uuid,
    signal: serde_json::Value,
) {
    // Reject oversized payloads (64 KB limit)
    const MAX_SIGNAL_SIZE: usize = 64 * 1024;
    if let Ok(encoded) = serde_json::to_string(&signal)
        && encoded.len() > MAX_SIGNAL_SIZE
    {
        send_error(
            state,
            sender_id,
            "Voice signal payload too large (max 64 KB)",
        );
        return;
    }

    // Validate signal type field (client sends "ice-candidate", not "candidate")
    let valid_types = ["offer", "answer", "ice-candidate"];
    match signal.get("type").and_then(|v| v.as_str()) {
        Some(t) if valid_types.contains(&t) => {}
        _ => {
            send_error(
                state,
                sender_id,
                "Voice signal must have a 'type' field with value 'offer', 'answer', or \
                 'ice-candidate'",
            );
            return;
        }
    }

    let is_member = match db::groups::is_member(&state.pool, conversation_id, sender_id).await {
        Ok(m) => m,
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return;
        }
    };
    if !is_member {
        send_error(state, sender_id, "Not a member of this conversation");
        return;
    }

    let kind = match db::groups::get_conversation_kind(&state.pool, conversation_id).await {
        Ok(Some(k)) => k,
        Ok(None) => {
            send_error(state, sender_id, "Conversation not found");
            return;
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return;
        }
    };

    if ConversationKind::from_str_opt(&kind) != Some(ConversationKind::Group) {
        send_error(
            state,
            sender_id,
            "Voice signaling is only supported in groups",
        );
        return;
    }

    let channel = match db::channels::get_channel(&state.pool, channel_id).await {
        Ok(Some(c)) => c,
        Ok(None) => {
            send_error(state, sender_id, "Channel not found");
            return;
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return;
        }
    };

    if channel.conversation_id != conversation_id {
        send_error(state, sender_id, "Channel is not part of this conversation");
        return;
    }

    if channel.kind != "voice" {
        send_error(
            state,
            sender_id,
            "Voice signaling is only valid for voice channels",
        );
        return;
    }

    let sender_in_channel =
        match db::channels::is_user_in_voice_channel(&state.pool, channel_id, sender_id).await {
            Ok(v) => v,
            Err(_) => {
                send_error(state, sender_id, "Database error");
                return;
            }
        };
    if !sender_in_channel {
        send_error(state, sender_id, "Join the voice channel before signaling");
        return;
    }

    let target_in_channel =
        match db::channels::is_user_in_voice_channel(&state.pool, channel_id, to_user_id).await {
            Ok(v) => v,
            Err(_) => {
                send_error(state, sender_id, "Database error");
                return;
            }
        };
    if !target_in_channel {
        send_error(state, sender_id, "Target user is not in this voice channel");
        return;
    }

    let event = ServerMessage::VoiceSignal {
        conversation_id,
        channel_id,
        from_user_id: sender_id,
        signal,
    };

    if let Ok(json) = serde_json::to_string(&event) {
        state.hub.send_to(&to_user_id, WsMessage::Text(json.into()));
    }
}

pub(super) fn send_error(state: &AppState, user_id: Uuid, message: &str) {
    let err = ServerMessage::Error {
        message: message.to_string(),
    };
    if let Ok(json) = serde_json::to_string(&err) {
        state.hub.send_to(&user_id, WsMessage::Text(json.into()));
    }
}

/// Handle a canvas event from a client.
///
/// - Looks up the channel, verifies sender is a group member, then broadcasts
///   the event to all other conversation members.
/// - For persistent event kinds ("stroke", "clear", "image_add",
///   "image_move", "image_remove") the canvas DB record is updated so new
///   joiners load the current board state.
/// - "avatar_move" is ephemeral (not persisted).
async fn handle_canvas_event(
    state: &AppState,
    sender_id: Uuid,
    channel_id: Uuid,
    kind: String,
    payload: serde_json::Value,
) {
    // Validate kind to prevent arbitrary strings reaching the DB.
    const VALID_KINDS: &[&str] = &[
        "stroke",
        "clear",
        "image_add",
        "image_move",
        "image_remove",
        "avatar_move",
    ];
    if !VALID_KINDS.contains(&kind.as_str()) {
        send_error(state, sender_id, "Invalid canvas event kind");
        return;
    }

    // Look up the channel to obtain the conversation_id.
    let channel = match db::channels::get_channel(&state.pool, channel_id).await {
        Ok(Some(c)) => c,
        Ok(None) => {
            send_error(state, sender_id, "Channel not found");
            return;
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return;
        }
    };

    let conversation_id = channel.conversation_id;

    // Verify sender is a member.
    let is_member = match db::groups::is_member(&state.pool, conversation_id, sender_id).await {
        Ok(m) => m,
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return;
        }
    };
    if !is_member {
        send_error(state, sender_id, "Not a member of this conversation");
        return;
    }

    // Persist state for non-ephemeral kinds.
    match kind.as_str() {
        "stroke" => {
            if let Err(e) =
                db::canvas::append_stroke(&state.pool, channel_id, payload.clone()).await
            {
                tracing::error!("canvas: failed to persist stroke for channel {channel_id}: {e:?}");
            }
        }
        "clear" => {
            if let Err(e) = db::canvas::clear_drawing(&state.pool, channel_id).await {
                tracing::error!("canvas: failed to clear drawing for channel {channel_id}: {e:?}");
            }
        }
        "image_add" => {
            if let Err(e) = db::canvas::add_image(&state.pool, channel_id, payload.clone()).await {
                tracing::error!("canvas: failed to persist image for channel {channel_id}: {e:?}");
            }
        }
        "image_move" => {
            if let Err(e) = db::canvas::update_image(&state.pool, channel_id, payload.clone()).await
            {
                tracing::error!("canvas: failed to update image for channel {channel_id}: {e:?}");
            }
        }
        "image_remove" => {
            let Some(id) = payload.get("id").and_then(|v| v.as_str()) else {
                send_error(state, sender_id, "image_remove requires an 'id' field");
                return;
            };
            if let Err(e) = db::canvas::remove_image(&state.pool, channel_id, id).await {
                tracing::error!(
                    "canvas: failed to remove image {id} for channel {channel_id}: {e:?}"
                );
            }
        }
        _ => {} // "avatar_move" — ephemeral, no DB write
    }

    // Broadcast to all other conversation members.
    let member_ids = match typing_service::get_member_ids_cached(&state.pool, conversation_id).await
    {
        Ok(ids) => ids,
        Err(_) => return,
    };

    let event = ServerMessage::CanvasEvent {
        channel_id,
        from_user_id: sender_id,
        kind,
        payload,
    };
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .broadcast_json(&member_ids, &json, Some(sender_id));
    }
}
