//! Voice-lounge canvas event handling: validate, persist, relay.

use std::sync::OnceLock;

use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::ws::error::send_error;
use crate::ws::events::canvas_validation::{self, ValidationError};
use crate::ws::protocol::ServerMessage;
use crate::ws::typing_service;

/// Rollout phase for the per-kind geometry/schema validators.
///
/// `LogOnly` runs the validators but never blocks the event — the canvas
/// behavior is unchanged from before validation existed, and mismatches
/// emit a structured `warn!` we can grep production logs for. After we've
/// observed `log_only` for ~2 weeks and confirmed legitimate clients pass,
/// the env flips to `enforce` and rejections start dropping events.
///
/// `Off` is an escape hatch in case of a false-positive incident.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ValidationMode {
    Off,
    LogOnly,
    Enforce,
}

impl ValidationMode {
    fn from_env_str(raw: Option<&str>) -> Self {
        match raw.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
            Some("off") => Self::Off,
            Some("enforce") => Self::Enforce,
            // Default + any unrecognized value: log_only. Unrecognized
            // values fall through to log_only so a typo doesn't accidentally
            // disable validation entirely.
            _ => Self::LogOnly,
        }
    }
}

fn validation_mode() -> ValidationMode {
    // Read once per process. Env changes require a server restart, which
    // matches every other env-driven knob in `config.rs`.
    static MODE: OnceLock<ValidationMode> = OnceLock::new();
    *MODE.get_or_init(|| {
        let mode =
            ValidationMode::from_env_str(std::env::var("CANVAS_VALIDATION_MODE").ok().as_deref());
        tracing::info!("CANVAS_VALIDATION_MODE = {:?}", mode);
        mode
    })
}

/// Apply per-kind validation per the active `CANVAS_VALIDATION_MODE`.
///
/// Returns `false` if the caller should stop processing the event (only
/// happens in `Enforce` mode on validation failure).  In `LogOnly` mode a
/// rejection is logged and the event continues through the pipeline.
fn apply_validation(
    state: &AppState,
    sender_id: Uuid,
    channel_id: Uuid,
    kind: &str,
    payload: &serde_json::Value,
) -> bool {
    let mode = validation_mode();
    if matches!(mode, ValidationMode::Off) {
        return true;
    }
    let Err(err) = canvas_validation::validate(kind, payload) else {
        return true;
    };
    log_validation_failure(sender_id, channel_id, kind, payload, &err);
    if matches!(mode, ValidationMode::Enforce) {
        send_error(state, sender_id, &err.code);
        return false;
    }
    true
}

fn log_validation_failure(
    sender_id: Uuid,
    channel_id: Uuid,
    kind: &str,
    payload: &serde_json::Value,
    err: &ValidationError,
) {
    // Truncate payload to 256 bytes so a misbehaving client can't flood
    // disk via the log pipeline.
    let snippet = serde_json::to_string(payload).unwrap_or_default();
    let truncated: String = snippet.chars().take(256).collect();
    tracing::warn!(
        sender_id = %sender_id,
        channel_id = %channel_id,
        kind = %kind,
        reason = %err.code,
        payload_snippet = %truncated,
        "canvas validation rejected payload",
    );
}

/// Persist canvas state for non-ephemeral event kinds.
/// Returns early if a hard error (cap reached) prevents broadcast.
async fn persist_canvas_state(
    state: &AppState,
    sender_id: Uuid,
    channel_id: Uuid,
    kind: &str,
    payload: &serde_json::Value,
) -> bool {
    match kind {
        "stroke" => match db::canvas::append_stroke(&state.pool, channel_id, payload.clone()).await
        {
            Ok(()) => true,
            Err(db::canvas::CanvasCapError::CapReached) => {
                send_error(state, sender_id, "Canvas stroke limit reached");
                false
            }
            Err(e) => {
                tracing::error!("canvas: failed to persist stroke for channel {channel_id}: {e:?}");
                true
            }
        },
        "clear" => {
            // The client's "Clear board" wipes both drawings AND images
            // locally and broadcasts a single `clear` event. Server used
            // to only erase drawing_data, leaving images_data persisted —
            // so the next user to join the channel saw ghost images that
            // the live participants had already cleared. Route to
            // clear_all to keep persisted state aligned with live state
            // (audit Finding 3, 2026-05-28).
            if let Err(e) = db::canvas::clear_all(&state.pool, channel_id).await {
                tracing::error!("canvas: failed to clear-all for channel {channel_id}: {e:?}");
            }
            true
        }
        "image_add" => {
            match db::canvas::add_image(&state.pool, channel_id, payload.clone()).await {
                Ok(()) => true,
                Err(db::canvas::CanvasCapError::CapReached) => {
                    send_error(state, sender_id, "Canvas image limit reached");
                    false
                }
                Err(e) => {
                    tracing::error!(
                        "canvas: failed to persist image for channel {channel_id}: {e:?}"
                    );
                    true
                }
            }
        }
        "image_move" => {
            if let Err(e) = db::canvas::update_image(&state.pool, channel_id, payload.clone()).await
            {
                tracing::error!("canvas: failed to update image for channel {channel_id}: {e:?}");
            }
            true
        }
        "image_remove" => {
            let Some(id) = payload.get("id").and_then(|v| v.as_str()) else {
                send_error(state, sender_id, "image_remove requires an 'id' field");
                return false;
            };
            if let Err(e) = db::canvas::remove_image(&state.pool, channel_id, id).await {
                tracing::error!(
                    "canvas: failed to remove image {id} for channel {channel_id}: {e:?}"
                );
            }
            true
        }
        // Ephemeral relays — relayed but never written to the DB.
        // Covers "avatar_move", "stroke_partial", "screenshare_move".
        _ => true,
    }
}

/// Verify sender is a member of the conversation.
async fn verify_membership(state: &AppState, sender_id: Uuid, conversation_id: Uuid) -> bool {
    match db::groups::is_member(&state.pool, conversation_id, sender_id).await {
        Ok(m) => {
            if !m {
                send_error(state, sender_id, "Not a member of this conversation");
            }
            m
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            false
        }
    }
}

/// Look up channel and validate it's a voice channel.
async fn lookup_voice_channel(state: &AppState, sender_id: Uuid, channel_id: Uuid) -> Option<Uuid> {
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

    if channel.kind != "voice" {
        send_error(
            state,
            sender_id,
            "Canvas events are only valid for voice channels",
        );
        return None;
    }

    Some(channel.conversation_id)
}

/// Handle a canvas event from a client.
///
/// - Looks up the channel, verifies sender is a group member, then broadcasts
///   the event to all other conversation members.
/// - For persistent event kinds ("stroke", "clear", "image_add",
///   "image_move", "image_remove") the canvas DB record is updated so new
///   joiners load the current board state.
/// - "avatar_move", "stroke_partial", and "screenshare_move" are
///   ephemeral (relayed but not persisted).
pub(in crate::ws) async fn handle_canvas_event(
    state: &AppState,
    sender_id: Uuid,
    channel_id: Uuid,
    kind: String,
    payload: serde_json::Value,
) {
    // Validate kind to prevent arbitrary strings reaching the DB.
    // stroke_partial is an ephemeral live-preview frame the client sends
    // mid-drag — relayed but never persisted (clients reconcile to the
    // final `stroke` on pointer-up). Adding it here unblocks remote
    // participants from seeing live drawings as the artist draws them
    // (user-reported 2026-05-27).
    const VALID_KINDS: &[&str] = &[
        "stroke",
        "stroke_partial",
        "clear",
        "image_add",
        "image_move",
        "image_remove",
        "avatar_move",
        // Screen-share window position relay. Ephemeral like avatar_move
        // — the canvas is a shared whiteboard, so when anyone drags a
        // screen-share window the other participants need to see it move
        // in real time. Never persisted; clients reconcile on join.
        "screenshare_move",
    ];
    if !VALID_KINDS.contains(&kind.as_str()) {
        send_error(state, sender_id, "Invalid canvas event kind");
        return;
    }

    // Per-kind schema/geometry validation. In the default `log_only` mode
    // mismatches emit a `warn!` and the event continues unchanged; once
    // `CANVAS_VALIDATION_MODE=enforce` is set, mismatches return a
    // `canvas.validation.*` error code and drop the event.
    if !apply_validation(state, sender_id, channel_id, &kind, &payload) {
        return;
    }

    let conversation_id = match lookup_voice_channel(state, sender_id, channel_id).await {
        Some(cid) => cid,
        None => return,
    };

    if !verify_membership(state, sender_id, conversation_id).await {
        return;
    }

    if !persist_canvas_state(state, sender_id, channel_id, &kind, &payload).await {
        return;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_mode_defaults_to_log_only_when_unset() {
        assert_eq!(ValidationMode::from_env_str(None), ValidationMode::LogOnly);
    }

    #[test]
    fn validation_mode_parses_enforce() {
        assert_eq!(
            ValidationMode::from_env_str(Some("enforce")),
            ValidationMode::Enforce
        );
    }

    #[test]
    fn validation_mode_parses_off() {
        assert_eq!(
            ValidationMode::from_env_str(Some("off")),
            ValidationMode::Off
        );
    }

    #[test]
    fn validation_mode_is_case_insensitive() {
        assert_eq!(
            ValidationMode::from_env_str(Some("ENFORCE")),
            ValidationMode::Enforce
        );
        assert_eq!(
            ValidationMode::from_env_str(Some("  Off  ")),
            ValidationMode::Off
        );
    }

    #[test]
    fn validation_mode_unknown_falls_back_to_log_only() {
        assert_eq!(
            ValidationMode::from_env_str(Some("strict")),
            ValidationMode::LogOnly
        );
    }
}
