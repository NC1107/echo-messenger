//! WebSocket message handling and routing.

use axum::extract::ws::{Message as WsMessage, WebSocket};
use chrono::{DateTime, Utc};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::mpsc;
use uuid::Uuid;

use sqlx;

use crate::db;
use crate::routes::AppState;

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

    // Deliver undelivered messages
    if let Ok(undelivered) = db::messages::get_undelivered(&state.pool, user_id).await {
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
        if !ids.is_empty() {
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
    }

    // Message receive loop
    while let Some(Ok(msg)) = receiver.next().await {
        match msg {
            WsMessage::Text(text) => {
                handle_text_message(&text, user_id, &username, &state).await;
            }
            WsMessage::Close(_) => break,
            _ => {}
        }
    }

    // Cleanup
    state.hub.unregister(user_id);
    send_task.abort();

    // Clean up stale voice sessions for this user (handles client crashes).
    if let Ok(removed_sessions) =
        db::channels::leave_all_user_voice_sessions(&state.pool, user_id).await
    {
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
                    for member_id in &member_ids {
                        state
                            .hub
                            .send_to(member_id, WsMessage::Text(json.clone().into()));
                    }
                }
            }
        }
    }

    // Broadcast offline presence to contacts
    broadcast_presence(&state, user_id, &username, "offline").await;

    tracing::info!("WebSocket disconnected: {} ({})", username, user_id);
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

    // Determine the conversation to send to.
    // If conversation_id is provided, use it (for group messages or explicit DM).
    // If to_user_id is provided without conversation_id, find/create DM conversation (backward compat).
    let conv_id = if let Some(cid) = conversation_id {
        // Verify sender is a member of this conversation
        match db::groups::is_member(&state.pool, cid, sender_id).await {
            Ok(true) => cid,
            Ok(false) => {
                send_error(state, sender_id, "Not a member of this conversation");
                return;
            }
            Err(_) => {
                send_error(state, sender_id, "Database error");
                return;
            }
        }
    } else if let Some(to_uid) = to_user_id {
        // Legacy DM path: verify contacts
        match db::contacts::are_contacts(&state.pool, sender_id, to_uid).await {
            Ok(true) => {}
            Ok(false) => {
                send_error(state, sender_id, "Not a contact");
                return;
            }
            Err(_) => {
                send_error(state, sender_id, "Database error");
                return;
            }
        }

        match db::messages::find_or_create_dm_conversation(&state.pool, sender_id, to_uid).await {
            Ok(id) => id,
            Err(_) => {
                send_error(state, sender_id, "Failed to create conversation");
                return;
            }
        }
    } else {
        send_error(
            state,
            sender_id,
            "Must provide conversation_id or to_user_id",
        );
        return;
    };

    // Enforce sender privacy preference for plaintext direct messages.
    // If a direct conversation has encryption disabled, treat outbound content
    // as plaintext and reject it when the sender has opted out.
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

    if conv_security.kind != "group" && channel_id.is_some() {
        send_error(
            state,
            sender_id,
            "channel_id is only valid for group conversations",
        );
        return;
    }

    let resolved_channel_id = if conv_security.kind == "group" {
        if let Some(cid) = channel_id {
            let channel = match db::channels::get_channel(&state.pool, cid).await {
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

            if channel.conversation_id != conv_id {
                send_error(state, sender_id, "Channel is not part of this conversation");
                return;
            }

            if channel.kind != "text" {
                send_error(
                    state,
                    sender_id,
                    "Messages can only be sent to text channels",
                );
                return;
            }

            Some(cid)
        } else {
            match db::channels::get_default_text_channel(&state.pool, conv_id).await {
                Ok(Some(channel)) => Some(channel.id),
                Ok(None) => {
                    send_error(state, sender_id, "No text channel found for this group");
                    return;
                }
                Err(_) => {
                    send_error(state, sender_id, "Database error");
                    return;
                }
            }
        }
    } else {
        None
    };

    if conv_security.kind == "direct" && !conv_security.is_encrypted {
        let privacy = match db::users::get_privacy_preferences(&state.pool, sender_id).await {
            Ok(Some(p)) => p,
            Ok(None) => {
                send_error(state, sender_id, "User not found");
                return;
            }
            Err(_) => {
                send_error(state, sender_id, "Database error");
                return;
            }
        };

        if !privacy.allow_unencrypted_dm {
            send_error(
                state,
                sender_id,
                "Plaintext direct messages are disabled in your privacy settings",
            );
            return;
        }
    }

    // Look up reply context if reply_to_id is provided
    let (reply_content, reply_username) = if let Some(rid) = reply_to_id {
        match sqlx::query_as::<_, (String, String)>(
            "SELECT m.content, u.username \
             FROM messages m JOIN users u ON u.id = m.sender_id \
             WHERE m.id = $1",
        )
        .bind(rid)
        .fetch_optional(&state.pool)
        .await
        {
            Ok(Some((c, u))) => (Some(c), Some(u)),
            _ => (None, None),
        }
    } else {
        (None, None)
    };

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

    // Fan out to all conversation members (except sender)
    let member_ids = match db::groups::get_conversation_member_ids(&state.pool, conv_id).await {
        Ok(ids) => ids,
        Err(_) => {
            tracing::error!("Failed to get conversation members for fan-out");
            return;
        }
    };

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
    let json = match serde_json::to_string(&deliver) {
        Ok(j) => j,
        Err(_) => return,
    };

    let mut delivered_ids = Vec::new();
    for member_id in &member_ids {
        if *member_id == sender_id {
            continue;
        }
        // Check if recipient has blocked the sender; if so, silently skip delivery
        if db::contacts::is_blocked(&state.pool, *member_id, sender_id)
            .await
            .unwrap_or(false)
        {
            continue;
        }
        if state
            .hub
            .send_to(member_id, WsMessage::Text(json.clone().into()))
        {
            delivered_ids.push(stored.id);
        }
    }

    if !delivered_ids.is_empty() {
        let _ = db::messages::mark_delivered(&state.pool, &[stored.id]).await;

        // Send delivery confirmation back to the sender
        let delivered_event = ServerMessage::Delivered {
            message_id: stored.id,
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
    if kind == "group"
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
    let json = match serde_json::to_string(&event) {
        Ok(j) => j,
        Err(_) => return,
    };

    for member_id in &member_ids {
        if *member_id == sender_id {
            continue;
        }
        state
            .hub
            .send_to(member_id, WsMessage::Text(json.clone().into()));
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
    let json = match serde_json::to_string(&event) {
        Ok(j) => j,
        Err(_) => return,
    };

    for member_id in &member_ids {
        if *member_id == sender_id {
            continue;
        }
        state
            .hub
            .send_to(member_id, WsMessage::Text(json.clone().into()));
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

    if kind != "group" {
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
