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
            handle_canvas_event(state, sender_id, channel_id, kind, payload).await;
        }
    }
}
