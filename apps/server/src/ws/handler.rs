//! WebSocket message handling and routing.

use axum::extract::ws::{Message as WsMessage, WebSocket};
use chrono::{DateTime, Utc};
use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::LazyLock;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;

/// In-memory cache for conversation membership checks used by the typing
/// indicator path.  Keyed by (user_id, conversation_id), stores the
/// tokio::time::Instant when membership was last verified.  Entries older
/// than `MEMBERSHIP_CACHE_TTL` are treated as expired and re-verified
/// against the database.
static MEMBERSHIP_CACHE: LazyLock<DashMap<(Uuid, Uuid), Instant>> = LazyLock::new(DashMap::new);
const MEMBERSHIP_CACHE_TTL: Duration = Duration::from_secs(60);

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
        /// Per-device ciphertexts: device_id (as string) -> base64 ciphertext.
        /// When present, enables multi-device delivery.
        #[serde(default)]
        device_contents: Option<HashMap<String, String>>,
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
}

#[derive(Serialize, Clone)]
#[serde(tag = "type")]
enum ServerMessage {
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
    broadcast_presence(&state, user_id, &username, "online").await;

    // Task: forward hub messages to WebSocket sink
    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sender.send(msg).await.is_err() {
                break;
            }
        }
    });

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

    deliver_undelivered_messages(&state, user_id).await;

    run_receive_loop(&mut receiver, user_id, device_id, &username, &state).await;

    // Cleanup
    state.hub.unregister(user_id, device_id);
    send_task.abort();
    ping_task.abort();

    cleanup_user_voice_sessions(&state, user_id).await;

    // Broadcast offline presence to contacts
    broadcast_presence(&state, user_id, &username, "offline").await;

    tracing::info!("WebSocket disconnected: {} ({})", username, user_id);
}

/// Deliver any messages that were stored while the user was offline, then mark
/// them delivered and notify the original senders.
async fn deliver_undelivered_messages(state: &AppState, user_id: Uuid) {
    let undelivered = match db::messages::get_undelivered(&state.pool, user_id).await {
        Ok(msgs) => msgs,
        Err(_) => return,
    };

    let ids: Vec<Uuid> = undelivered.iter().map(|m| m.id).collect();

    for msg in &undelivered {
        let server_msg = ServerMessage::NewMessage {
            message_id: msg.id,
            from_user_id: msg.sender_id,
            from_device_id: None, // Offline delivery doesn't track sender device
            from_username: msg.sender_username.clone(),
            conversation_id: msg.conversation_id,
            channel_id: msg.channel_id,
            content: msg.content.clone(),
            timestamp: msg.created_at,
            reply_to_id: msg.reply_to_id,
            reply_to_content: msg.reply_to_content.clone(),
            reply_to_username: msg.reply_to_username.clone(),
        };
        if let Ok(json) = serde_json::to_string(&server_msg) {
            let _ = state
                .hub
                .send_to_user(&user_id, WsMessage::Text(json.into()));
        }
    }

    if ids.is_empty() {
        return;
    }

    let _ = db::messages::mark_delivered(&state.pool, &ids).await;

    // Notify original senders that their messages were delivered
    for msg in &undelivered {
        let delivered_event = ServerMessage::Delivered {
            message_id: msg.id,
            conversation_id: msg.conversation_id,
        };
        if let Ok(json) = serde_json::to_string(&delivered_event) {
            state
                .hub
                .send_to(&msg.sender_id, WsMessage::Text(json.into()));
        }
    }
}

/// Rate-limited WebSocket receive loop.
///
/// Uses a token bucket algorithm: 30 messages per 10-second window
/// (refill rate = 3 tokens/sec, burst cap = 30). When the bucket is
/// empty the message is dropped and an error is sent to the client;
/// the connection stays open so legitimate traffic can resume once
/// tokens regenerate.
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

    let mut tokens: f64 = BUCKET_CAPACITY;
    let mut last_refill = Instant::now();

    while let Some(Ok(msg)) = receiver.next().await {
        // Refill tokens based on elapsed time.
        let now = Instant::now();
        let elapsed = now.duration_since(last_refill).as_secs_f64();
        tokens = (tokens + elapsed * REFILL_RATE).min(BUCKET_CAPACITY);
        last_refill = now;

        match msg {
            WsMessage::Text(text) => {
                if tokens < 1.0 {
                    tracing::warn!(
                        user_id = %user_id,
                        username = %username,
                        "WebSocket rate limit exceeded, dropping message"
                    );
                    send_error(state, user_id, "Rate limit exceeded, please slow down");
                    continue;
                }
                tokens -= 1.0;
                handle_text_message(&text, user_id, device_id, username, state).await;
            }
            WsMessage::Close(_) => break,
            _ => {}
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
        let member_ids =
            db::groups::get_conversation_member_ids(&state.pool, conversation_id).await;
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
            device_contents,
        } => {
            handle_send_message(
                state,
                sender_id,
                sender_device_id,
                sender_username,
                conversation_id,
                channel_id,
                to_user_id,
                content,
                reply_to_id,
                device_contents,
            )
            .await;
        }
        ClientMessage::Typing {
            conversation_id,
            channel_id,
        } => {
            handle_typing(
                state,
                sender_id,
                sender_username,
                conversation_id,
                channel_id,
            )
            .await;
        }
        ClientMessage::ReadReceipt { conversation_id } => {
            handle_read_receipt(state, sender_id, conversation_id).await;
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
    let is_member = match db::groups::is_member(&state.pool, conversation_id, sender_id).await {
        Ok(m) => m,
        Err(_) => return,
    };
    if !is_member {
        return;
    }

    let member_ids =
        match db::groups::get_conversation_member_ids(&state.pool, conversation_id).await {
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

#[allow(clippy::too_many_arguments)]
async fn handle_send_message(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    sender_username: &str,
    conversation_id: Option<Uuid>,
    channel_id: Option<Uuid>,
    to_user_id: Option<Uuid>,
    content: String,
    reply_to_id: Option<Uuid>,
    device_contents: Option<HashMap<String, String>>,
) {
    // Validate message content length
    const MAX_MESSAGE_LENGTH: usize = 10_000;
    if content.len() > MAX_MESSAGE_LENGTH {
        send_error(
            state,
            sender_id,
            &format!(
                "Message too long: {} characters (max {})",
                content.len(),
                MAX_MESSAGE_LENGTH
            ),
        );
        return;
    }

    let Some(conv_id) = resolve_conversation(state, sender_id, conversation_id, to_user_id).await
    else {
        return;
    };

    // Enforce encrypted-only direct messages.
    let conv_security = match db::messages::get_conversation_security(&state.pool, conv_id).await {
        Ok(Some(row)) => row,
        Ok(None) => {
            send_error(state, sender_id, "Conversation not found");
            return;
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return;
        }
    };

    let conv_kind = ConversationKind::from_str_opt(&conv_security.kind);
    if conv_kind != Some(ConversationKind::Group) && channel_id.is_some() {
        send_error(
            state,
            sender_id,
            "channel_id is only valid for group conversations",
        );
        return;
    }

    let Some(resolved_channel_id) =
        resolve_channel(state, sender_id, conv_id, channel_id, conv_kind).await
    else {
        return;
    };

    if conv_kind == Some(ConversationKind::Direct) && !conv_security.is_encrypted {
        send_error(
            state,
            sender_id,
            "Direct messages must be end-to-end encrypted",
        );
        return;
    }

    let (reply_content, reply_username) = lookup_reply_context(&state.pool, reply_to_id).await;

    // Store message, send confirmation, and deliver to sender's other devices.
    let Some(stored) = store_and_confirm(
        state,
        sender_id,
        sender_device_id,
        conv_id,
        resolved_channel_id,
        &content,
        reply_to_id,
        &device_contents,
    )
    .await
    else {
        return;
    };

    let deliver = ServerMessage::NewMessage {
        message_id: stored.id,
        from_user_id: sender_id,
        from_device_id: Some(sender_device_id),
        from_username: sender_username.to_string(),
        conversation_id: conv_id,
        channel_id: stored.channel_id,
        content,
        timestamp: stored.created_at,
        reply_to_id,
        reply_to_content: reply_content,
        reply_to_username: reply_username,
    };

    fanout_message(
        state,
        sender_id,
        sender_device_id,
        conv_id,
        &deliver,
        stored.id,
        conv_security.is_encrypted,
        device_contents,
    )
    .await;
}

/// Persist the message to the database, store per-device ciphertexts, send
/// a `message_sent` confirmation to the originating device, and relay the
/// message to the sender's other devices.  Returns the stored message row
/// on success, or `None` after sending an error to the client.
#[allow(clippy::too_many_arguments)]
async fn store_and_confirm(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    conv_id: Uuid,
    resolved_channel_id: Option<Uuid>,
    content: &str,
    reply_to_id: Option<Uuid>,
    device_contents: &Option<HashMap<String, String>>,
) -> Option<db::messages::MessageRow> {
    // Store message in DB
    let stored = match db::messages::store_message(
        &state.pool,
        conv_id,
        resolved_channel_id,
        sender_id,
        content,
        reply_to_id,
    )
    .await
    {
        Ok(row) => row,
        Err(_) => {
            send_error(state, sender_id, "Failed to store message");
            return None;
        }
    };

    // Store per-device ciphertexts if present
    if let Some(dc) = device_contents {
        let entries: Vec<(i32, &str)> = dc
            .iter()
            .filter_map(|(k, v)| k.parse::<i32>().ok().map(|id| (id, v.as_str())))
            .collect();
        if !entries.is_empty()
            && let Err(e) =
                db::messages::store_device_contents(&state.pool, stored.id, &entries).await
        {
            tracing::error!("Failed to store device contents: {e:?}");
        }
    }

    // Send confirmation to sender's device
    let confirm = ServerMessage::MessageSent {
        message_id: stored.id,
        conversation_id: conv_id,
        channel_id: stored.channel_id,
        timestamp: stored.created_at,
    };
    if let Ok(json) = serde_json::to_string(&confirm) {
        state
            .hub
            .send_to_device(&sender_id, sender_device_id, WsMessage::Text(json.into()));
    }

    // Self-device delivery: notify sender's OTHER devices about outgoing message
    if let Some(dc) = device_contents {
        for (device_id_str, ciphertext) in dc {
            if let Ok(did) = device_id_str.parse::<i32>() {
                if did == sender_device_id {
                    continue; // Don't send to the originating device
                }
                let self_msg = ServerMessage::SelfMessage {
                    message_id: stored.id,
                    from_device_id: sender_device_id,
                    conversation_id: conv_id,
                    channel_id: stored.channel_id,
                    content: ciphertext.clone(),
                    timestamp: stored.created_at,
                    reply_to_id,
                };
                if let Ok(json) = serde_json::to_string(&self_msg) {
                    state
                        .hub
                        .send_to_device(&sender_id, did, WsMessage::Text(json.into()));
                }
            }
        }
    }

    Some(stored)
}

/// Resolve the target conversation from either an explicit conversation_id or a to_user_id.
/// Returns None and sends an error to the sender on failure.
async fn resolve_conversation(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Option<Uuid>,
    to_user_id: Option<Uuid>,
) -> Option<Uuid> {
    if let Some(cid) = conversation_id {
        // Verify sender is a member of this conversation
        match db::groups::is_member(&state.pool, cid, sender_id).await {
            Ok(true) => Some(cid),
            Ok(false) => {
                send_error(state, sender_id, "Not a member of this conversation");
                None
            }
            Err(_) => {
                send_error(state, sender_id, "Database error");
                None
            }
        }
    } else if let Some(to_uid) = to_user_id {
        // Legacy DM path: verify contacts
        match db::contacts::are_contacts(&state.pool, sender_id, to_uid).await {
            Ok(true) => {}
            Ok(false) => {
                send_error(state, sender_id, "Not a contact");
                return None;
            }
            Err(_) => {
                send_error(state, sender_id, "Database error");
                return None;
            }
        }

        match db::messages::find_or_create_dm_conversation(&state.pool, sender_id, to_uid).await {
            Ok(id) => Some(id),
            Err(_) => {
                send_error(state, sender_id, "Failed to create conversation");
                None
            }
        }
    } else {
        send_error(
            state,
            sender_id,
            "Must provide conversation_id or to_user_id",
        );
        None
    }
}

/// Resolve the target channel for a message.
/// Returns `Some(Some(channel_id))` for groups, `Some(None)` for DMs, `None` on error.
async fn resolve_channel(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
    channel_id: Option<Uuid>,
    conv_kind: Option<ConversationKind>,
) -> Option<Option<Uuid>> {
    if conv_kind != Some(ConversationKind::Group) {
        return Some(None);
    }

    if let Some(cid) = channel_id {
        validate_explicit_channel(state, sender_id, conv_id, cid).await
    } else {
        resolve_default_text_channel(state, sender_id, conv_id).await
    }
}

/// Validate that an explicit channel_id belongs to the conversation and is a text channel.
async fn validate_explicit_channel(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
    channel_id: Uuid,
) -> Option<Option<Uuid>> {
    let channel = match db::channels::get_channel(&state.pool, channel_id).await {
        Ok(Some(c)) => c,
        Ok(None) => {
            send_error(state, sender_id, "Channel not found");
            return None;
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return None;
        }
    };

    if channel.conversation_id != conv_id {
        send_error(state, sender_id, "Channel is not part of this conversation");
        return None;
    }

    if channel.kind != "text" {
        send_error(
            state,
            sender_id,
            "Messages can only be sent to text channels",
        );
        return None;
    }

    Some(Some(channel_id))
}

/// Look up the default text channel for a group conversation.
async fn resolve_default_text_channel(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
) -> Option<Option<Uuid>> {
    match db::channels::get_default_text_channel(&state.pool, conv_id).await {
        Ok(Some(channel)) => Some(Some(channel.id)),
        Ok(None) => {
            send_error(state, sender_id, "No text channel found for this group");
            None
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            None
        }
    }
}

/// Look up reply context (content and username) for a given reply_to_id.
async fn lookup_reply_context(
    pool: &sqlx::PgPool,
    reply_to_id: Option<Uuid>,
) -> (Option<String>, Option<String>) {
    if let Some(rid) = reply_to_id {
        match db::messages::lookup_reply_context(pool, rid).await {
            Ok(Some((c, u))) => (Some(c), Some(u)),
            _ => (None, None),
        }
    } else {
        (None, None)
    }
}

/// Common fields extracted from a `ServerMessage::NewMessage` for per-device rewriting
/// and push notification content.
struct NewMessageFields {
    message_id: Uuid,
    from_user_id: Uuid,
    from_device_id: Option<i32>,
    from_username: String,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
    content: String,
    timestamp: DateTime<Utc>,
    reply_to_id: Option<Uuid>,
    reply_to_content: Option<String>,
    reply_to_username: Option<String>,
}

impl NewMessageFields {
    /// Extract fields from a `ServerMessage::NewMessage`, returning `None` for other variants.
    fn extract(message: &ServerMessage) -> Option<Self> {
        match message {
            ServerMessage::NewMessage {
                message_id,
                from_user_id,
                from_device_id,
                from_username,
                conversation_id,
                channel_id,
                content,
                timestamp,
                reply_to_id,
                reply_to_content,
                reply_to_username,
            } => Some(Self {
                message_id: *message_id,
                from_user_id: *from_user_id,
                from_device_id: *from_device_id,
                from_username: from_username.clone(),
                conversation_id: *conversation_id,
                channel_id: *channel_id,
                content: content.clone(),
                timestamp: *timestamp,
                reply_to_id: *reply_to_id,
                reply_to_content: reply_to_content.clone(),
                reply_to_username: reply_to_username.clone(),
            }),
            _ => None,
        }
    }
}

/// Pre-serialize per-device JSON messages once (keyed by device_id) to avoid
/// re-serializing the same message for every member in the fanout loop.
fn build_per_device_json(
    fields: &NewMessageFields,
    device_contents: &HashMap<String, String>,
) -> Vec<(i32, String)> {
    device_contents
        .iter()
        .filter_map(|(device_id_str, ciphertext)| {
            let did = device_id_str.parse::<i32>().ok()?;
            let per_device_msg = ServerMessage::NewMessage {
                message_id: fields.message_id,
                from_user_id: fields.from_user_id,
                from_device_id: fields.from_device_id,
                from_username: fields.from_username.clone(),
                conversation_id: fields.conversation_id,
                channel_id: fields.channel_id,
                content: ciphertext.clone(),
                timestamp: fields.timestamp,
                reply_to_id: fields.reply_to_id,
                reply_to_content: fields.reply_to_content.clone(),
                reply_to_username: fields.reply_to_username.clone(),
            };
            let json = serde_json::to_string(&per_device_msg).ok()?;
            Some((did, json))
        })
        .collect()
}

/// Deliver a message to a single member via per-device or legacy delivery.
/// Returns `true` if the member received the message on at least one device.
fn deliver_to_member(
    hub: &crate::ws::hub::Hub,
    member_id: &Uuid,
    per_device_json: Option<&[(i32, String)]>,
    legacy_json: Option<&str>,
) -> bool {
    if let Some(device_jsons) = per_device_json {
        device_jsons.iter().any(|(did, json)| {
            hub.send_to_device(member_id, *did, WsMessage::Text(json.clone().into()))
        })
    } else if let Some(json) = legacy_json {
        hub.send_to_user(member_id, WsMessage::Text(json.to_owned().into()))
    } else {
        false
    }
}

/// Mark messages as delivered in the DB and send a delivery confirmation back to the sender.
async fn send_delivery_confirmation(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    stored_id: Uuid,
    conv_id: Uuid,
) {
    let _ = db::messages::mark_delivered(&state.pool, &[stored_id]).await;

    let delivered_event = ServerMessage::Delivered {
        message_id: stored_id,
        conversation_id: conv_id,
    };
    if let Ok(delivered_json) = serde_json::to_string(&delivered_event) {
        state.hub.send_to_device(
            &sender_id,
            sender_device_id,
            WsMessage::Text(delivered_json.into()),
        );
    }
}

/// Spawn a background task to send push notifications to offline users.
fn spawn_push_notifications(
    pool: sqlx::PgPool,
    offline_user_ids: Vec<Uuid>,
    sender_name: &str,
    content: &str,
    is_encrypted: bool,
    conv_id: Uuid,
    stored_id: Uuid,
) {
    let sender_name = sender_name.to_string();
    let content = content.to_string();
    let handle = tokio::spawn(async move {
        crate::push::notify_offline_users(
            &pool,
            &offline_user_ids,
            &sender_name,
            &content,
            is_encrypted,
            conv_id,
            stored_id,
        )
        .await;
    });
    tokio::spawn(async move {
        if let Err(e) = handle.await {
            tracing::error!("Push notification task failed for conv {conv_id}: {e}");
        }
    });
}

/// Fan out a message to all conversation members (except sender), with block filtering
/// and delivery tracking. Supports per-device ciphertext delivery for multi-device.
#[allow(clippy::too_many_arguments)]
async fn fanout_message(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    conv_id: Uuid,
    message: &ServerMessage,
    stored_id: Uuid,
    is_encrypted: bool,
    device_contents: Option<HashMap<String, String>>,
) {
    let Some(fields) = NewMessageFields::extract(message) else {
        tracing::error!("fanout_message called with non-NewMessage variant");
        return;
    };

    let member_ids = match db::groups::get_conversation_member_ids(&state.pool, conv_id).await {
        Ok(ids) => ids,
        Err(_) => {
            tracing::error!("Failed to get conversation members for fan-out");
            return;
        }
    };

    // Batch check which members have blocked the sender (single query instead of N+1)
    let blockers: Vec<Uuid> = db::contacts::get_blockers_of(&state.pool, &member_ids, sender_id)
        .await
        .unwrap_or_default();

    // Pre-serialize per-device JSON messages and legacy fallback
    let per_device_json = device_contents
        .as_ref()
        .map(|dc| build_per_device_json(&fields, dc));
    let legacy_json = serde_json::to_string(message).ok();

    let mut any_delivered = false;
    let mut offline_user_ids = Vec::new();

    let eligible = member_ids
        .iter()
        .filter(|id| **id != sender_id && !blockers.contains(id));

    for member_id in eligible {
        let delivered = deliver_to_member(
            &state.hub,
            member_id,
            per_device_json.as_deref(),
            legacy_json.as_deref(),
        );
        if delivered {
            any_delivered = true;
        } else {
            offline_user_ids.push(*member_id);
        }
    }

    if any_delivered {
        send_delivery_confirmation(state, sender_id, sender_device_id, stored_id, conv_id).await;
    }

    if !offline_user_ids.is_empty() {
        spawn_push_notifications(
            state.pool.clone(),
            offline_user_ids,
            &fields.from_username,
            &fields.content,
            is_encrypted,
            conv_id,
            stored_id,
        );
    }
}

/// Check conversation membership using the in-memory cache.
/// Returns true if the user is a verified member. Cache entries expire
/// after `MEMBERSHIP_CACHE_TTL` (60 seconds).
async fn check_membership_cached(
    pool: &sqlx::PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
) -> bool {
    let cache_key = (user_id, conversation_id);

    // Fast path: check cache
    if let Some(entry) = MEMBERSHIP_CACHE.get(&cache_key) {
        if entry.value().elapsed() < MEMBERSHIP_CACHE_TTL {
            return true;
        }
    }

    // Slow path: hit database
    let is_member = match db::groups::is_member(pool, conversation_id, user_id).await {
        Ok(m) => m,
        Err(_) => return false,
    };

    if is_member {
        MEMBERSHIP_CACHE.insert(cache_key, Instant::now());
    } else {
        // Evict stale positive entry if membership was revoked
        MEMBERSHIP_CACHE.remove(&cache_key);
    }

    is_member
}

async fn handle_typing(
    state: &AppState,
    sender_id: Uuid,
    sender_username: &str,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
) {
    // Verify membership via cache (avoids DB hit on every keystroke)
    if !check_membership_cached(&state.pool, conversation_id, sender_id).await {
        return;
    }

    let kind = match db::groups::get_conversation_kind(&state.pool, conversation_id).await {
        Ok(Some(k)) => k,
        _ => return,
    };

    let mut resolved_channel_id = None;
    if ConversationKind::from_str_opt(&kind) == Some(ConversationKind::Group)
        && let Some(cid) = channel_id
    {
        let channel = match db::channels::get_channel(&state.pool, cid).await {
            Ok(Some(c)) => c,
            _ => return,
        };
        if channel.conversation_id != conversation_id || channel.kind != "text" {
            return;
        }
        resolved_channel_id = Some(cid);
    }

    let member_ids =
        match db::groups::get_conversation_member_ids(&state.pool, conversation_id).await {
            Ok(ids) => ids,
            Err(_) => return,
        };

    let event = ServerMessage::Typing {
        conversation_id,
        channel_id: resolved_channel_id,
        user_id: sender_id,
        from_username: sender_username.to_string(),
    };
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .broadcast_json(&member_ids, &json, Some(sender_id));
    }
}

async fn handle_read_receipt(state: &AppState, sender_id: Uuid, conversation_id: Uuid) {
    // Verify membership
    let is_member = match db::groups::is_member(&state.pool, conversation_id, sender_id).await {
        Ok(m) => m,
        Err(_) => return,
    };
    if !is_member {
        return;
    }

    // Enforce sender preference: when disabled, do not persist or broadcast.
    let privacy = match db::users::get_privacy_preferences(&state.pool, sender_id).await {
        Ok(Some(p)) => p,
        _ => return,
    };
    if !privacy.read_receipts_enabled {
        return;
    }

    // Persist the read receipt
    let _ = db::reactions::mark_read(&state.pool, conversation_id, sender_id).await;

    // Broadcast to other members
    let member_ids =
        match db::groups::get_conversation_member_ids(&state.pool, conversation_id).await {
            Ok(ids) => ids,
            Err(_) => return,
        };

    let event = ServerMessage::ReadReceipt {
        conversation_id,
        user_id: sender_id,
    };
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

async fn broadcast_presence(state: &AppState, user_id: Uuid, username: &str, status: &str) {
    let contact_ids = match db::contacts::list_contact_user_ids(&state.pool, user_id).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!("Failed to fetch contacts for presence broadcast: {e}");
            return;
        }
    };

    let presence = serde_json::json!({
        "type": "presence",
        "user_id": user_id,
        "username": username,
        "status": status,
    });
    let json = match serde_json::to_string(&presence) {
        Ok(j) => j,
        Err(_) => return,
    };

    for cid in &contact_ids {
        state.hub.send_to(cid, WsMessage::Text(json.clone().into()));
    }
}

fn send_error(state: &AppState, user_id: Uuid, message: &str) {
    let err = ServerMessage::Error {
        message: message.to_string(),
    };
    if let Ok(json) = serde_json::to_string(&err) {
        state.hub.send_to(&user_id, WsMessage::Text(json.into()));
    }
}
