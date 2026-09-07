//! Generic handler for simple broadcast-to-conversation events.
//!
//! Used by `key_reset`, `call_started`, and other events that just need a
//! membership check followed by a fanout to every member — and to the sender's
//! sibling devices — except the originating device.

use uuid::Uuid;

use crate::routes::AppState;
use crate::ws::protocol::ServerMessage;
use crate::ws::typing_service;

/// Verifies membership, then broadcasts `build_event(...)` to all conversation
/// members. The sender's *other* devices still receive it (so a call-started /
/// key-reset from device A reaches device B); only the originating device is
/// excluded (VL-19 device-id-vs-user-id class).
pub(in crate::ws) async fn handle_broadcast_event<F>(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    sender_username: &str,
    conversation_id: Uuid,
    build_event: F,
) where
    F: FnOnce(Uuid, String, Uuid) -> ServerMessage,
{
    if !typing_service::check_membership_cached(&state.pool, conversation_id, sender_id).await {
        return;
    }

    let member_ids = match typing_service::get_member_ids_cached(&state.pool, conversation_id).await
    {
        Ok(ids) => ids,
        Err(_) => return,
    };

    let event = build_event(sender_id, sender_username.to_string(), conversation_id);
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .broadcast_json_except_device(&member_ids, &json, sender_id, sender_device_id);
    }
}
