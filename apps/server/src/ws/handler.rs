//! WebSocket message handling and routing.

use axum::extract::ws::{Message as WsMessage, WebSocket};
use chrono::{DateTime, Utc};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;
use uuid::Uuid;

use sqlx;

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;

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
}

#[derive(Serialize)]
#[serde(tag = "type")]
enum ServerMessage {
    #[serde(rename = "new_message")]
    NewMessage {
        message_id: Uuid,
        from_user_id: Uuid,
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
}

pub async fn handle_socket(
    socket: WebSocket,
    user_id: Uuid,
    username: String,
    state: Arc<AppState>,
) {
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<WsMessage>();

    // Register in hub
    state.hub.register(user_id, tx);

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
    let ping_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        // The first tick fires immediately; skip it.
        interval.tick().await;
        loop {
            interval.tick().await;
            // Protocol-level Ping (proxy keepalive; invisible to browsers).
            ping_hub.send_to(&ping_user_id, WsMessage::Ping(vec![].into()));
            // Application-level heartbeat (visible to all clients).
            let hb = r#"{"type":"heartbeat"}"#.to_string();
            if !ping_hub.send_to(&ping_user_id, WsMessage::Text(hb.into())) {
                break;
            }
        }
    });

    deliver_undelivered_messages(&state, user_id).await;

    run_receive_loop(&mut receiver, user_id, &username, &state).await;

    // Cleanup
    state.hub.unregister(user_id);
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
            let _ = state.hub.send_to(&user_id, WsMessage::Text(json.into()));
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
                handle_text_message(&text, user_id, username, state).await;
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

async fn handle_text_message(text: &str, sender_id: Uuid, sender_username: &str, state: &AppState) {
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
        } => {
            handle_send_message(
                state,
                sender_id,
                sender_username,
                conversation_id,
                channel_id,
                to_user_id,
                content,
                reply_to_id,
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
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_send_message(
    state: &AppState,
    sender_id: Uuid,
    sender_username: &str,
    conversation_id: Option<Uuid>,
    channel_id: Option<Uuid>,
    to_user_id: Option<Uuid>,
    content: String,
    reply_to_id: Option<Uuid>,
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

    // Store message
    let stored = match db::messages::store_message(
        &state.pool,
        conv_id,
        resolved_channel_id,
        sender_id,
        &content,
        reply_to_id,
    )
    .await
    {
        Ok(row) => row,
        Err(_) => {
            send_error(state, sender_id, "Failed to store message");
            return;
        }
    };

    // Send confirmation to sender
    let confirm = ServerMessage::MessageSent {
        message_id: stored.id,
        conversation_id: conv_id,
        channel_id: stored.channel_id,
        timestamp: stored.created_at,
    };
    if let Ok(json) = serde_json::to_string(&confirm) {
        state.hub.send_to(&sender_id, WsMessage::Text(json.into()));
    }

    let deliver = ServerMessage::NewMessage {
        message_id: stored.id,
        from_user_id: sender_id,
        from_username: sender_username.to_string(),
        conversation_id: conv_id,
        channel_id: stored.channel_id,
        content,
        timestamp: stored.created_at,
        reply_to_id,
        reply_to_content: reply_content,
        reply_to_username: reply_username,
    };

    fanout_message(state, sender_id, conv_id, &deliver, stored.id).await;
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
        match sqlx::query_as::<_, (String, String)>(
            "SELECT m.content, u.username \
             FROM messages m JOIN users u ON u.id = m.sender_id \
             WHERE m.id = $1",
        )
        .bind(rid)
        .fetch_optional(pool)
        .await
        {
            Ok(Some((c, u))) => (Some(c), Some(u)),
            _ => (None, None),
        }
    } else {
        (None, None)
    }
}

/// Fan out a message to all conversation members (except sender), with block filtering
/// and delivery tracking.
async fn fanout_message(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
    message: &ServerMessage,
    stored_id: Uuid,
) {
    let member_ids = match db::groups::get_conversation_member_ids(&state.pool, conv_id).await {
        Ok(ids) => ids,
        Err(_) => {
            tracing::error!("Failed to get conversation members for fan-out");
            return;
        }
    };

    let json = match serde_json::to_string(message) {
        Ok(j) => j,
        Err(_) => return,
    };

    // Batch check which members have blocked the sender (single query instead of N+1)
    let blockers: Vec<Uuid> = db::contacts::get_blockers_of(&state.pool, &member_ids, sender_id)
        .await
        .unwrap_or_default();

    let mut any_delivered = false;
    for member_id in &member_ids {
        if *member_id == sender_id {
            continue;
        }
        if blockers.contains(member_id) {
            continue;
        }
        if state
            .hub
            .send_to(member_id, WsMessage::Text(json.clone().into()))
        {
            any_delivered = true;
        }
    }

    if any_delivered {
        let _ = db::messages::mark_delivered(&state.pool, &[stored_id]).await;

        // Send delivery confirmation back to the sender
        let delivered_event = ServerMessage::Delivered {
            message_id: stored_id,
            conversation_id: conv_id,
        };
        if let Ok(delivered_json) = serde_json::to_string(&delivered_event) {
            state
                .hub
                .send_to(&sender_id, WsMessage::Text(delivered_json.into()));
        }
    }
}

async fn handle_typing(
    state: &AppState,
    sender_id: Uuid,
    sender_username: &str,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
) {
    // Verify membership
    let is_member = match db::groups::is_member(&state.pool, conversation_id, sender_id).await {
        Ok(m) => m,
        Err(_) => return,
    };
    if !is_member {
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
    let contacts = match db::contacts::list_contacts(&state.pool, user_id).await {
        Ok(c) => c,
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

    for contact in &contacts {
        state
            .hub
            .send_to(&contact.user_id, WsMessage::Text(json.clone().into()));
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
