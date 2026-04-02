//! Message and conversation REST endpoints.

use axum::Json;
use axum::extract::ws::Message as WsMessage;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use chrono::{DateTime, NaiveDateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

/// Lenient DateTime parser: accepts both `2026-01-01T00:00:00Z` and `2026-01-01T00:00:00.000`
fn deserialize_lenient_datetime<'de, D>(deserializer: D) -> Result<Option<DateTime<Utc>>, D::Error>
where
    D: Deserializer<'de>,
{
    let opt: Option<String> = Option::deserialize(deserializer)?;
    match opt {
        None => Ok(None),
        Some(s) => {
            // Try RFC 3339 first (with timezone)
            if let Ok(dt) = DateTime::parse_from_rfc3339(&s) {
                return Ok(Some(dt.with_timezone(&Utc)));
            }
            // Fallback: NaiveDateTime (no timezone, assume UTC)
            if let Ok(naive) = NaiveDateTime::parse_from_str(&s, "%Y-%m-%dT%H:%M:%S%.f") {
                return Ok(Some(naive.and_utc()));
            }
            if let Ok(naive) = NaiveDateTime::parse_from_str(&s, "%Y-%m-%dT%H:%M:%S") {
                return Ok(Some(naive.and_utc()));
            }
            Err(serde::de::Error::custom(format!(
                "cannot parse datetime: {s}"
            )))
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct MessageQuery {
    #[serde(default, deserialize_with = "deserialize_lenient_datetime")]
    pub before: Option<DateTime<Utc>>,
    pub limit: Option<i64>,
    pub channel_id: Option<Uuid>,
}

#[derive(Debug, Serialize)]
pub struct ConversationListItem {
    pub conversation_id: Uuid,
    pub kind: String,
    pub title: Option<String>,
    pub is_encrypted: bool,
    pub members: Vec<MemberInfo>,
    pub last_message: Option<LastMessageInfo>,
    pub unread_count: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MemberInfo {
    pub user_id: Uuid,
    pub username: String,
    pub role: Option<String>,
    pub avatar_url: Option<String>,
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
    is_encrypted: bool,
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
            c.is_encrypted, \
            (SELECT json_agg(json_build_object( \
                'user_id', u.id, 'username', u.username, 'role', cm2.role, 'avatar_url', u.avatar_url \
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
            is_encrypted: row.is_encrypted,
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

    if let Some(channel_id) = params.channel_id {
        let conversation_kind = db::groups::get_conversation_kind(&state.pool, conversation_id)
            .await
            .map_err(|_| AppError::internal("Database error"))?
            .ok_or_else(|| AppError::bad_request("Conversation not found"))?;

        if conversation_kind != "group" {
            return Err(AppError::bad_request(
                "channel_id is only supported for group conversations",
            ));
        }

        let channel = db::channels::get_channel(&state.pool, channel_id)
            .await
            .map_err(|_| AppError::internal("Database error"))?
            .ok_or_else(|| AppError::bad_request("Channel not found"))?;

        if channel.conversation_id != conversation_id {
            return Err(AppError::bad_request(
                "Channel is not part of this conversation",
            ));
        }

        if channel.kind != "text" {
            return Err(AppError::bad_request(
                "Only text channels can contain messages",
            ));
        }
    }

    let limit = params.limit.unwrap_or(50).min(100);
    let messages = db::messages::get_messages(
        &state.pool,
        conversation_id,
        params.channel_id,
        params.before,
        limit,
    )
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

// ---------------------------------------------------------------------------
// PUT /api/conversations/:conversation_id/encryption -- toggle encryption
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ToggleEncryptionRequest {
    pub is_encrypted: bool,
}

pub async fn toggle_encryption(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<ToggleEncryptionRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Verify caller is a member of this conversation
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;
    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    db::messages::set_conversation_encrypted(&state.pool, conversation_id, body.is_encrypted)
        .await
        .map_err(|_| AppError::internal("Failed to update encryption setting"))?;

    // Broadcast to all conversation members so both sides update immediately.
    let member_ids = db::groups::get_conversation_member_ids(&state.pool, conversation_id)
        .await
        .unwrap_or_default();
    let event = serde_json::json!({
        "type": "encryption_toggled",
        "conversation_id": conversation_id,
        "is_encrypted": body.is_encrypted,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        for member_id in &member_ids {
            state
                .hub
                .send_to(member_id, WsMessage::Text(json.clone().into()));
        }
    }

    Ok(Json(serde_json::json!({
        "conversation_id": conversation_id,
        "is_encrypted": body.is_encrypted,
    })))
}
