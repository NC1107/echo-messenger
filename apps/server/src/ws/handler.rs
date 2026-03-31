//! WebSocket message handling and routing.

use axum::extract::ws::{Message as WsMessage, WebSocket};
use chrono::{DateTime, Utc};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;

#[derive(Deserialize)]
#[serde(tag = "type")]
enum ClientMessage {
    #[serde(rename = "send_message")]
    SendMessage {
        conversation_id: Option<Uuid>,
        to_user_id: Option<Uuid>,
        content: String,
    },
    #[serde(rename = "typing")]
    Typing { conversation_id: Uuid },
    #[serde(rename = "read_receipt")]
    ReadReceipt { conversation_id: Uuid },
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
        content: String,
        timestamp: DateTime<Utc>,
    },
    #[serde(rename = "message_sent")]
    MessageSent {
        message_id: Uuid,
        conversation_id: Uuid,
        timestamp: DateTime<Utc>,
    },
    #[serde(rename = "typing")]
    Typing {
        conversation_id: Uuid,
        user_id: Uuid,
        username: String,
    },
    #[serde(rename = "read_receipt")]
    ReadReceipt {
        conversation_id: Uuid,
        user_id: Uuid,
    },
    #[serde(rename = "error")]
    Error { message: String },
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
                content: msg.content.clone(),
                timestamp: msg.created_at,
            };
            if let Ok(json) = serde_json::to_string(&server_msg) {
                let _ = state.hub.send_to(&user_id, WsMessage::Text(json.into()));
            }
        }
        if !ids.is_empty() {
            let _ = db::messages::mark_delivered(&state.pool, &ids).await;
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
            to_user_id,
            content,
        } => {
            handle_send_message(state, sender_id, sender_username, conversation_id, to_user_id, content).await;
        }
        ClientMessage::Typing { conversation_id } => {
            handle_typing(state, sender_id, sender_username, conversation_id).await;
        }
        ClientMessage::ReadReceipt { conversation_id } => {
            handle_read_receipt(state, sender_id, conversation_id).await;
        }
    }
}

async fn handle_send_message(
    state: &AppState,
    sender_id: Uuid,
    sender_username: &str,
    conversation_id: Option<Uuid>,
    to_user_id: Option<Uuid>,
    content: String,
) {
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
        send_error(state, sender_id, "Must provide conversation_id or to_user_id");
        return;
    };

    // Store message
    let stored = match db::messages::store_message(&state.pool, conv_id, sender_id, &content).await {
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
        content,
        timestamp: stored.created_at,
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
        if state.hub.send_to(member_id, WsMessage::Text(json.clone().into())) {
            delivered_ids.push(stored.id);
        }
    }

    if !delivered_ids.is_empty() {
        let _ = db::messages::mark_delivered(&state.pool, &[stored.id]).await;
    }
}

async fn handle_typing(
    state: &AppState,
    sender_id: Uuid,
    sender_username: &str,
    conversation_id: Uuid,
) {
    // Verify membership
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

    let event = ServerMessage::Typing {
        conversation_id,
        user_id: sender_id,
        username: sender_username.to_string(),
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

fn send_error(state: &AppState, user_id: Uuid, message: &str) {
    let err = ServerMessage::Error {
        message: message.to_string(),
    };
    if let Ok(json) = serde_json::to_string(&err) {
        state.hub.send_to(&user_id, WsMessage::Text(json.into()));
    }
}
