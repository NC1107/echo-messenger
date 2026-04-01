//! Message and conversation REST endpoints.

use axum::Json;
use axum::extract::ws::Message as WsMessage;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct MessageQuery {
    pub before: Option<DateTime<Utc>>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct ConversationListItem {
    pub conversation_id: Uuid,
    pub kind: String,
    pub title: Option<String>,
    pub members: Vec<MemberInfo>,
    pub last_message: Option<LastMessageInfo>,
    pub unread_count: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MemberInfo {
    pub user_id: Uuid,
    pub username: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct LastMessageInfo {
    pub content: String,
    pub sender_username: String,
    pub created_at: DateTime<Utc>,
}

/// Raw row returned by the single optimized list_conversations query.
#[derive(Debug, sqlx::FromRow)]
struct ConversationFullRow {
    conversation_id: Uuid,
    kind: String,
    title: Option<String>,
    members_json: Option<serde_json::Value>,
    last_message_json: Option<serde_json::Value>,
    unread_count: i64,
}

pub async fn list_conversations(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    // Single query with subqueries for members, last message, and unread count.
    // This replaces the previous 3N+1 query pattern.
    let rows = sqlx::query_as::<_, ConversationFullRow>(
        "SELECT \
            c.id AS conversation_id, \
            c.kind, \
            c.title, \
            (SELECT json_agg(json_build_object( \
                'user_id', u.id, 'username', u.username \
            )) FROM conversation_members cm2 \
            JOIN users u ON cm2.user_id = u.id \
            WHERE cm2.conversation_id = c.id) AS members_json, \
            (SELECT row_to_json(sub) FROM ( \
                SELECT m.content, m.created_at, u2.username AS sender_username \
                FROM messages m \
                JOIN users u2 ON m.sender_id = u2.id \
                WHERE m.conversation_id = c.id AND m.deleted_at IS NULL \
                ORDER BY m.created_at DESC LIMIT 1 \
            ) sub) AS last_message_json, \
            (SELECT COUNT(*) FROM messages m2 \
                WHERE m2.conversation_id = c.id \
                AND m2.sender_id != $1 \
                AND m2.deleted_at IS NULL \
                AND m2.created_at > COALESCE( \
                    (SELECT last_read_at FROM read_receipts \
                     WHERE conversation_id = c.id AND user_id = $1), \
                    '1970-01-01'::timestamptz \
                ) \
            ) AS unread_count \
         FROM conversations c \
         JOIN conversation_members cm ON cm.conversation_id = c.id \
         WHERE cm.user_id = $1 \
         ORDER BY ( \
            SELECT MAX(m3.created_at) FROM messages m3 \
            WHERE m3.conversation_id = c.id \
         ) DESC NULLS LAST",
    )
    .bind(auth.user_id)
    .fetch_all(&state.pool)
    .await
    .map_err(|e| {
        tracing::error!("list_conversations query error: {e}");
        AppError::internal("Database error")
    })?;

    let mut result = Vec::with_capacity(rows.len());

    for row in rows {
        // Parse members from JSON array
        let members: Vec<MemberInfo> = row
            .members_json
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default();

        // Parse last message from JSON object
        let last_message: Option<LastMessageInfo> = row
            .last_message_json
            .and_then(|v| serde_json::from_value(v).ok());

        result.push(ConversationListItem {
            conversation_id: row.conversation_id,
            kind: row.kind,
            title: row.title,
            members,
            last_message,
            unread_count: row.unread_count,
        });
    }

    Ok(Json(result))
}

pub async fn get_messages(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
    Query(params): Query<MessageQuery>,
) -> Result<impl IntoResponse, AppError> {
    // Verify the user is a member of this conversation
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    let limit = params.limit.unwrap_or(50).min(100);
    let messages = db::messages::get_messages(&state.pool, conversation_id, params.before, limit)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok(Json(messages))
}

#[derive(Debug, Deserialize)]
pub struct CreateDmRequest {
    pub peer_user_id: Uuid,
}

pub async fn create_dm(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateDmRequest>,
) -> Result<impl IntoResponse, AppError> {
    let are_contacts = db::contacts::are_contacts(&state.pool, auth.user_id, req.peer_user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;
    if !are_contacts {
        return Err(AppError::bad_request("Not a contact"));
    }
    let conversation_id =
        db::messages::find_or_create_dm_conversation(&state.pool, auth.user_id, req.peer_user_id)
            .await
            .map_err(|_| AppError::internal("Failed to create conversation"))?;
    Ok(Json(
        serde_json::json!({ "conversation_id": conversation_id }),
    ))
}

// ---------------------------------------------------------------------------
// DELETE /api/messages/:message_id -- soft-delete a message
// ---------------------------------------------------------------------------

pub async fn delete_message(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(message_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let conversation_id = db::messages::delete_message(&state.pool, message_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::bad_request("Message not found or you are not the sender"))?;

    // Broadcast to conversation members via WebSocket
    let member_ids = db::groups::get_conversation_member_ids(&state.pool, conversation_id)
        .await
        .unwrap_or_default();

    let event = serde_json::json!({
        "type": "message_deleted",
        "message_id": message_id,
        "conversation_id": conversation_id,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        for member_id in &member_ids {
            state
                .hub
                .send_to(member_id, WsMessage::Text(json.clone().into()));
        }
    }

    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// PUT /api/messages/:message_id -- edit a message
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct EditMessageRequest {
    pub content: String,
}

pub async fn edit_message(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(message_id): Path<Uuid>,
    Json(body): Json<EditMessageRequest>,
) -> Result<impl IntoResponse, AppError> {
    if body.content.is_empty() {
        return Err(AppError::bad_request("Content cannot be empty"));
    }
    if body.content.len() > 10_000 {
        return Err(AppError::bad_request("Content too long"));
    }

    let (conversation_id, edited_at) =
        db::messages::edit_message(&state.pool, message_id, auth.user_id, &body.content)
            .await
            .map_err(|_| AppError::internal("Database error"))?
            .ok_or_else(|| AppError::bad_request("Message not found or you are not the sender"))?;

    // Broadcast to conversation members via WebSocket
    let member_ids = db::groups::get_conversation_member_ids(&state.pool, conversation_id)
        .await
        .unwrap_or_default();

    let event = serde_json::json!({
        "type": "message_edited",
        "message_id": message_id,
        "conversation_id": conversation_id,
        "content": body.content,
        "edited_at": edited_at,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        for member_id in &member_ids {
            state
                .hub
                .send_to(member_id, WsMessage::Text(json.clone().into()));
        }
    }

    Ok(Json(serde_json::json!({
        "message_id": message_id,
        "edited_at": edited_at,
    })))
}
