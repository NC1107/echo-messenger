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
        "stroke" => {
            match db::canvas::append_stroke(&state.pool, channel_id, sender_id, payload.clone())
                .await
            {
                Ok(()) => true,
                Err(db::canvas::CanvasCapError::CapReached) => {
                    send_error(state, sender_id, "Canvas stroke limit reached");
                    false
                }
                Err(e) => {
                    tracing::error!(
                        "canvas: failed to persist stroke for channel {channel_id}: {e:?}"
                    );
                    true
                }
            }
        }
        "clear" => {
            // The client's "Clear board" wipes both drawings AND images
            // locally and broadcasts a single `clear` event. Server used
            // to only erase drawing_data, leaving images_data persisted —
            // so the next user to join the channel saw ghost images that
            // the live participants had already cleared. Route to
            // clear_all to keep persisted state aligned with live state
            // (audit Finding 3, 2026-05-28).
            //
            // VL-15: honor the `scope`. A missing scope defaults to "all"
            // (the historical behavior). `scope: "mine"` wipes only the
            // sender's own strokes/images so one member can clear their
            // contribution without nuking the whole board.
            let scope = payload
                .get("scope")
                .and_then(|v| v.as_str())
                .unwrap_or("all");
            let result = if scope == "mine" {
                db::canvas::clear_user_drawings(&state.pool, channel_id, sender_id).await
            } else {
                db::canvas::clear_all(&state.pool, channel_id).await
            };
            if let Err(e) = result {
                tracing::error!(
                    "canvas: failed to clear (scope={scope}) for channel {channel_id}: {e:?}"
                );
            }
            true
        }
        "image_add" => {
            // VL-16: the validator only confirms the url is shaped like
            // `/api/media/<uuid>`. Confirm the sender can actually access
            // that media before persisting/broadcasting, so a member can't
            // pin someone else's private upload onto the shared board by
            // guessing/replaying its id (#1332).
            if !verify_image_media_access(state, sender_id, payload).await {
                return false;
            }
            match db::canvas::add_image(&state.pool, channel_id, sender_id, payload.clone()).await {
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

/// Verify the sender can access the media referenced by an `image_add`
/// payload. Returns `false` (and sends a user-facing error) when the url is
/// not a parseable `/api/media/<uuid>` reference or the sender lacks access.
async fn verify_image_media_access(
    state: &AppState,
    sender_id: Uuid,
    payload: &serde_json::Value,
) -> bool {
    let Some(media_id) = canvas_validation::media_id_from_image_add(payload) else {
        send_error(
            state,
            sender_id,
            "image_add url is not a valid media reference",
        );
        return false;
    };
    match db::media::can_user_access_media(&state.pool, media_id, sender_id).await {
        Ok(true) => true,
        Ok(false) => {
            send_error(state, sender_id, "You do not have access to that media");
            false
        }
        Err(e) => {
            tracing::error!("canvas: media access check failed for {media_id}: {e:?}");
            send_error(state, sender_id, "Database error");
            false
        }
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
/// - "canvas_authority_claim" is the explicit-handoff event from the
///   non-authority device; payload is empty. See
///   `docs/voice-lounge/03-multi-device.md`.
/// - Canvas authority: when a sender has multiple devices for the same
///   `(user_id, channel_id)`, only the device that holds authority may
///   emit writes. Non-authority writes are **silently dropped** (no error
///   response) so a rogue device doesn't retry-storm the server.
pub(in crate::ws) async fn handle_canvas_event(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
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
        // Explicit handoff from a non-authority device — the client taps
        // the canvas to claim authority. Authority logic only; never
        // persisted and never broadcast as a `canvas_event`.
        "canvas_authority_claim",
    ];
    if !VALID_KINDS.contains(&kind.as_str()) {
        send_error(state, sender_id, "Invalid canvas event kind");
        return;
    }

    // VL-27: resolve the channel + verify membership BEFORE running the
    // per-kind validator. Otherwise a connected non-member could submit
    // payloads for any channel_id and probe the `canvas.validation.*` error
    // codes (a schema oracle) and burn validation CPU on unauthorized input.
    let conversation_id = match lookup_voice_channel(state, sender_id, channel_id).await {
        Some(cid) => cid,
        None => return,
    };

    if !verify_membership(state, sender_id, conversation_id).await {
        return;
    }

    // Per-kind schema/geometry validation. In the default `log_only` mode
    // mismatches emit a `warn!` and the event continues unchanged; once
    // `CANVAS_VALIDATION_MODE=enforce` is set, mismatches return a
    // `canvas.validation.*` error code and drop the event.
    if !apply_validation(state, sender_id, channel_id, &kind, &payload) {
        return;
    }

    // Explicit handoff is its own short path — claim, broadcast change if
    // it took, never persist or relay as a `canvas_event`.
    if kind == "canvas_authority_claim" {
        handle_authority_claim(
            state,
            sender_id,
            sender_device_id,
            channel_id,
            conversation_id,
        )
        .await;
        return;
    }

    // Write-side authority gate: drop silently if a different device holds
    // authority for this user. Implicit claim if no device has claimed yet
    // — first writer wins.
    if !gate_authority(
        state,
        sender_id,
        sender_device_id,
        channel_id,
        conversation_id,
    )
    .await
    {
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

/// Returns true if the sender's device may write to this canvas. When no
/// device has claimed yet, the first writer implicitly takes authority and
/// the broadcast goes out so other members render the read-only pill.
/// Non-authority writes return false and the caller drops the event
/// silently (no `send_error`).
async fn gate_authority(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    channel_id: Uuid,
    conversation_id: Uuid,
) -> bool {
    match state.canvas_authority.current(sender_id, channel_id) {
        Some(holder) => holder == sender_device_id,
        None => {
            // Implicit claim. Other peers learn via canvas_authority_changed
            // so the other devices for this user can render the pill.
            if state
                .canvas_authority
                .claim_if_absent(sender_id, channel_id, sender_device_id)
            {
                broadcast_authority_changed(
                    state,
                    sender_id,
                    sender_device_id,
                    channel_id,
                    conversation_id,
                )
                .await;
                true
            } else {
                false
            }
        }
    }
}

/// Process an explicit `canvas_authority_claim`. Honors the 1-second grace
/// window encoded in `CanvasAuthority::claim` so a fast double-tap from two
/// devices can't oscillate.
async fn handle_authority_claim(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    channel_id: Uuid,
    conversation_id: Uuid,
) {
    if state
        .canvas_authority
        .claim(sender_id, channel_id, sender_device_id)
    {
        broadcast_authority_changed(
            state,
            sender_id,
            sender_device_id,
            channel_id,
            conversation_id,
        )
        .await;
    }
}

/// Fan out a `canvas_authority_changed` to every lounge member (including
/// the new authority's other devices). Other clients use this to flip
/// their own draw-locks and render the read-only pill.
async fn broadcast_authority_changed(
    state: &AppState,
    user_id: Uuid,
    device_id: i32,
    channel_id: Uuid,
    conversation_id: Uuid,
) {
    let Ok(member_ids) = typing_service::get_member_ids_cached(&state.pool, conversation_id).await
    else {
        return;
    };
    let event = ServerMessage::CanvasAuthorityChanged {
        channel_id,
        user_id,
        device_id,
    };
    if let Ok(json) = serde_json::to_string(&event) {
        // No `exclude` — the sender's other devices need to learn too, and
        // the sending device itself benefits from idempotent state sync.
        state.hub.broadcast_json(&member_ids, &json, None);
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
