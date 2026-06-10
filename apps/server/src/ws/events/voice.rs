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

    // Membership, conversation kind, and channel metadata are served from the
    // shared 60s WS caches (same as the typing path) so the WebRTC signaling
    // hot path — which fires dozens of frames/sec per peer-pair during ICE
    // negotiation — does not hit the DB for these on every frame (#1338 / VL-28).
    if !typing_service::check_membership_cached(&state.pool, conversation_id, sender_id).await {
        send_error(state, sender_id, "Not a member of this conversation");
        return;
    }

    let kind =
        match typing_service::get_conversation_kind_cached(&state.pool, conversation_id).await {
            Some(k) => k,
            None => {
                send_error(state, sender_id, "Conversation not found");
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

    let (channel_conversation_id, channel_kind) =
        match typing_service::get_channel_meta_cached(&state.pool, channel_id).await {
            Some(meta) => meta,
            None => {
                send_error(state, sender_id, "Channel not found");
                return;
            }
        };
    if channel_conversation_id != conversation_id {
        send_error(state, sender_id, "Channel is not part of this conversation");
        return;
    }
    if channel_kind != "voice" {
        send_error(
            state,
            sender_id,
            "Voice signaling is only valid for voice channels",
        );
        return;
    }

    // Live voice presence is volatile, so it is NOT cached — but both checks
    // (sender + target) collapse into a single round-trip.
    let present = match db::channels::users_in_voice_channel(
        &state.pool,
        channel_id,
        &[sender_id, to_user_id],
    )
    .await
    {
        Ok(set) => set,
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return;
        }
    };
    if !present.contains(&sender_id) {
        send_error(state, sender_id, "Join the voice channel before signaling");
        return;
    }
    if !present.contains(&to_user_id) {
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
}
