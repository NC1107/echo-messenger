//! Voice-lounge canvas event handling: validate, persist, relay.

use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::ws::error::send_error;
use crate::ws::protocol::ServerMessage;
use crate::ws::typing_service;

/// Handle a canvas event from a client.
///
/// - Looks up the channel, verifies sender is a group member, then broadcasts
///   the event to all other conversation members.
/// - For persistent event kinds ("stroke", "clear", "image_add",
///   "image_move", "image_remove") the canvas DB record is updated so new
///   joiners load the current board state.
/// - "avatar_move" is ephemeral (not persisted).
pub(in crate::ws) async fn handle_canvas_event(
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

    // Reject canvas events sent to non-voice channels (canvas is a sub-feature
    // of voice lounges; text channels do not have a canvas).
    if channel.kind != "voice" {
        send_error(
            state,
            sender_id,
            "Canvas events are only valid for voice channels",
        );
        return;
    }

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
            match db::canvas::append_stroke(&state.pool, channel_id, payload.clone()).await {
                Ok(()) => {}
                Err(db::canvas::CanvasCapError::CapReached) => {
                    send_error(state, sender_id, "Canvas stroke limit reached");
                    return;
                }
                Err(e) => {
                    tracing::error!(
                        "canvas: failed to persist stroke for channel {channel_id}: {e:?}"
                    );
                }
            }
        }
        "clear" => {
            if let Err(e) = db::canvas::clear_drawing(&state.pool, channel_id).await {
                tracing::error!("canvas: failed to clear drawing for channel {channel_id}: {e:?}");
            }
        }
        "image_add" => {
            match db::canvas::add_image(&state.pool, channel_id, payload.clone()).await {
                Ok(()) => {}
                Err(db::canvas::CanvasCapError::CapReached) => {
                    send_error(state, sender_id, "Canvas image limit reached");
                    return;
                }
                Err(e) => {
                    tracing::error!(
                        "canvas: failed to persist image for channel {channel_id}: {e:?}"
                    );
                }
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
