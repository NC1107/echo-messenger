//! Reaction and read receipt REST endpoints.

use axum::Json;
use axum::extract::ws::Message as WsMessage;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx};

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct AddReactionRequest {
    pub emoji: String,
}

#[derive(Debug, Serialize)]
pub struct ReactionEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    pub message_id: Uuid,
    pub conversation_id: Uuid,
    pub user_id: Uuid,
    pub username: String,
    pub emoji: String,
    pub action: String,
}

/// POST /api/messages/:message_id/reactions -- Add a reaction.
pub async fn add_reaction(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(message_id): Path<Uuid>,
    Json(body): Json<AddReactionRequest>,
) -> Result<impl IntoResponse, AppError> {
    if body.emoji.is_empty() || body.emoji.len() > 32 {
        return Err(AppError::bad_request(
            "Emoji must be between 1 and 32 characters",
        ));
    }

    // Get conversation for this message
    let conversation_id = db::reactions::get_message_conversation_id(&state.pool, message_id)
        .await
        .db_ctx("add_reaction/get_conversation")?
        .ok_or_else(|| AppError::bad_request("Message not found"))?;

    // Verify membership
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .db_ctx("add_reaction/is_member")?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    let reaction = db::reactions::add_reaction(&state.pool, message_id, auth.user_id, &body.emoji)
        .await
        .db_ctx("add_reaction/insert")?;

    // Look up username for broadcast
    let user = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .db_ctx("add_reaction/find_user")?
        .ok_or_else(|| AppError::internal("User not found"))?;

    // Broadcast to conversation members
    let event = ReactionEvent {
        event_type: "reaction".to_string(),
        message_id,
        conversation_id,
        user_id: auth.user_id,
        username: user.username,
        emoji: body.emoji,
        action: "add".to_string(),
    };

    broadcast_to_conversation(&state, conversation_id, &event, None).await;

    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({ "reaction_id": reaction.id })),
    ))
}

/// DELETE /api/messages/:message_id/reactions/:emoji -- Remove own reaction.
pub async fn remove_reaction(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((message_id, emoji)): Path<(Uuid, String)>,
) -> Result<impl IntoResponse, AppError> {
    // Get conversation for this message
    let conversation_id = db::reactions::get_message_conversation_id(&state.pool, message_id)
        .await
        .db_ctx("remove_reaction/get_conversation")?
        .ok_or_else(|| AppError::bad_request("Message not found"))?;

    // Verify membership
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .db_ctx("remove_reaction/is_member")?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    let removed = db::reactions::remove_reaction(&state.pool, message_id, auth.user_id, &emoji)
        .await
        .db_ctx("remove_reaction/delete")?;

    if !removed {
        return Err(AppError::bad_request("Reaction not found"));
    }

    // Look up username for broadcast
    let user = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .db_ctx("remove_reaction/find_user")?
        .ok_or_else(|| AppError::internal("User not found"))?;

    // Broadcast removal to conversation members
    let event = ReactionEvent {
        event_type: "reaction".to_string(),
        message_id,
        conversation_id,
        user_id: auth.user_id,
        username: user.username,
        emoji,
        action: "remove".to_string(),
    };

    broadcast_to_conversation(&state, conversation_id, &event, None).await;

    Ok(Json(serde_json::json!({ "status": "removed" })))
}

/// POST /api/conversations/:id/read -- Mark conversation as read.
pub async fn mark_read(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Verify membership
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .db_ctx("mark_read/is_member")?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    let privacy = db::users::get_privacy_preferences(&state.pool, auth.user_id)
        .await
        .db_ctx("mark_read/get_privacy")?
        .ok_or_else(|| AppError::bad_request("User not found"))?;

    if !privacy.read_receipts_enabled {
        return Ok(Json(serde_json::json!({
            "status": "ignored",
            "reason": "read_receipts_disabled"
        })));
    }

    db::reactions::mark_read(&state.pool, conversation_id, auth.user_id)
        .await
        .db_ctx("mark_read/update")?;

    Ok(Json(serde_json::json!({ "status": "read" })))
}

/// Broadcast a serializable event to all members of a conversation (optionally excluding one user).
async fn broadcast_to_conversation<T: Serialize>(
    state: &AppState,
    conversation_id: Uuid,
    event: &T,
    exclude_user_id: Option<Uuid>,
) {
    let member_ids =
        match db::groups::get_conversation_member_ids(&state.pool, conversation_id).await {
            Ok(ids) => ids,
            Err(e) => {
                tracing::error!("Failed to get conversation members for broadcast: {:?}", e);
                return;
            }
        };

    let json = match serde_json::to_string(event) {
        Ok(j) => j,
        Err(e) => {
            tracing::error!("Failed to serialize broadcast event: {:?}", e);
            return;
        }
    };

    let msg = WsMessage::Text(json.as_str().into());
    for member_id in member_ids {
        if Some(member_id) == exclude_user_id {
            continue;
        }
        state.hub.send_to(&member_id, msg.clone());
    }
}
