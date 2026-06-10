//! Voice-channel WebRTC signaling and stale-session cleanup.

use axum::extract::ws::Message as WsMessage;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;
use crate::ws::error::send_error;
use crate::ws::protocol::ServerMessage;
use crate::ws::typing_service;

pub(in crate::ws) async fn handle_voice_signal(
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

/// Clean up stale voice sessions for a disconnecting user and broadcast
/// leave events to group members.
pub(in crate::ws) async fn cleanup_user_voice_sessions(state: &AppState, user_id: Uuid) {
    let removed_sessions =
        match db::channels::leave_all_user_voice_sessions(&state.pool, user_id).await {
            Ok(sessions) => sessions,
            Err(_) => return,
        };

    for (channel_id, conversation_id) in removed_sessions {
        broadcast_voice_leave(state, user_id, conversation_id, channel_id).await;
    }
}

/// Drop a (now-removed) member's voice presence within a single conversation
/// and broadcast the leave to remaining members (VL-24).
///
/// Called from the kick / ban / leave-group path so a removed participant no
/// longer shows up in the lounge and the server stops counting them, without
/// waiting for the 60s stale-session sweep. This is the server-side half of
/// the eviction story; actively booting them off the LiveKit SFU still needs a
/// management client (see `routes::voice::evict_from_voice_deferred`).
pub async fn evict_member_voice_sessions(state: &AppState, conversation_id: Uuid, user_id: Uuid) {
    let removed = match db::channels::leave_conversation_voice_sessions(
        &state.pool,
        conversation_id,
        user_id,
    )
    .await
    {
        Ok(channels) => channels,
        Err(e) => {
            tracing::warn!("Failed to clear voice sessions for evicted member: {e:?}");
            return;
        }
    };

    for channel_id in removed {
        broadcast_voice_leave(state, user_id, conversation_id, channel_id).await;
    }
}

/// Clear canvas authority and tell remaining members a user left a voice
/// channel. Shared by the disconnect sweep and the kick/ban path.
async fn broadcast_voice_leave(
    state: &AppState,
    user_id: Uuid,
    conversation_id: Uuid,
    channel_id: Uuid,
) {
    // Clear per-lounge canvas authority so the next device to draw
    // reclaims fresh. See docs/voice-lounge/03-multi-device.md.
    state.canvas_authority.clear_on_leave(user_id, channel_id);

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
