//! Parse a single client frame and dispatch to the matching event handler.

use uuid::Uuid;

use crate::routes::AppState;
use crate::ws::error::send_error;
use crate::ws::events::{
    broadcast::handle_broadcast_event, canvas::handle_canvas_event, voice::handle_voice_signal,
};
use crate::ws::message_service;
use crate::ws::protocol::{ClientMessage, ServerMessage};
use crate::ws::typing_service;

/// Maximum WebSocket text frame size (64 KB).  Frames larger than this are
/// rejected before JSON parsing to prevent memory exhaustion from oversized
/// payloads.  Legitimate messages are well under this limit (max message
/// content is 10 KB, and the JSON envelope adds minimal overhead).
const MAX_WS_FRAME_BYTES: usize = 65_536;

/// TD-35: per-field cap for the voice-signal `signal` payload. Realistic
/// WebRTC SDPs are 1–4 KB; ICE candidates are tens of bytes. 8 KB is loose
/// enough to allow growth without giving an attacker a 64 KB amplification
/// vector across every conversation member 30× per second.
const MAX_VOICE_SIGNAL_BYTES: usize = 8 * 1024;

/// TD-35: per-field cap for the canvas-event `payload`. Canvas events fire
/// per stroke segment and per pointer move; bounding individual segments to
/// 16 KB prevents a sender from using the per-frame 64 KB allowance as a
/// fan-out bandwidth amplifier.
const MAX_CANVAS_PAYLOAD_BYTES: usize = 16 * 1024;

/// Helper: estimate the serialized size of a `serde_json::Value` without
/// emitting a fresh allocation if we can avoid it. `serde_json::to_string`
/// is used because re-serialization is the canonical "size on the wire";
/// any cheaper proxy would mis-estimate string-escape expansion.
fn json_bytes(value: &serde_json::Value) -> usize {
    serde_json::to_string(value)
        .map(|s| s.len())
        .unwrap_or(usize::MAX)
}

pub(in crate::ws) async fn handle_text_message(
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
            // TD-74: don't echo the serde_json parser's internal byte/line
            // position back to the client — it lets attackers fingerprint
            // the parser and probe field tolerances cheaply. Log the
            // detail server-side instead so we still have it for support.
            tracing::debug!(sender_id = %sender_id, error = %e, "invalid client frame");
            send_error(state, sender_id, "Invalid message");
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
            client_message_id,
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
                client_message_id,
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
            // TD-35: bound the inner JSON payload before relaying. The 64 KB
            // frame cap alone let one peer cost N×64 KB per ICE candidate
            // across an in-call group.
            let signal_bytes = json_bytes(&signal);
            if signal_bytes > MAX_VOICE_SIGNAL_BYTES {
                tracing::warn!(
                    sender_id = %sender_id,
                    conversation_id = %conversation_id,
                    bytes = signal_bytes,
                    "rejected oversized voice signal payload",
                );
                send_error(
                    state,
                    sender_id,
                    &format!(
                        "voice signal too large ({signal_bytes} bytes, max {MAX_VOICE_SIGNAL_BYTES})"
                    ),
                );
                return;
            }
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
            // TD-35: bound the canvas payload before relaying/persisting.
            // Stroke segments and pointer moves should each fit in a few
            // hundred bytes; 16 KB is loose enough to allow image-add
            // descriptors without enabling a fan-out amplifier.
            let payload_bytes = json_bytes(&payload);
            if payload_bytes > MAX_CANVAS_PAYLOAD_BYTES {
                tracing::warn!(
                    sender_id = %sender_id,
                    channel_id = %channel_id,
                    kind = %kind,
                    bytes = payload_bytes,
                    "rejected oversized canvas payload",
                );
                send_error(
                    state,
                    sender_id,
                    &format!(
                        "canvas payload too large ({payload_bytes} bytes, max {MAX_CANVAS_PAYLOAD_BYTES})"
                    ),
                );
                return;
            }
            // Limit `kind` too — it's a small enum-like discriminator.
            if kind.len() > 64 {
                send_error(state, sender_id, "canvas event kind too long");
                return;
            }
            handle_canvas_event(state, sender_id, channel_id, kind, payload).await;
        }
    }
}
