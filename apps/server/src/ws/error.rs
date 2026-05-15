//! Shared helper for sending an error frame to a single user.

use axum::extract::ws::Message as WsMessage;
use uuid::Uuid;

use crate::routes::AppState;
use crate::ws::protocol::ServerMessage;

pub fn send_error(state: &AppState, user_id: Uuid, message: &str) {
    let err = ServerMessage::Error {
        message: message.to_string(),
    };
    if let Ok(json) = serde_json::to_string(&err) {
        state.hub.send_to(&user_id, WsMessage::Text(json.into()));
    }
}
