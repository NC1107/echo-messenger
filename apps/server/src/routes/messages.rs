//! Message and conversation REST endpoints.

use axum::Json;
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
use crate::types::{ConversationKind, Role};

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
    pub icon_url: Option<String>,
    pub is_encrypted: bool,
    pub is_muted: bool,
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
    icon_url: Option<String>,
    is_encrypted: bool,
    is_muted: bool,
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
            c.icon_url, \
            c.is_encrypted, \
            cm.is_muted, \
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
            icon_url: row.icon_url,
            is_encrypted: row.is_encrypted,
            is_muted: row.is_muted,
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
        .map_err(|e| {
            tracing::error!("DB error in get_messages/is_member: {e:?}");
            AppError::internal("Database error")
        })?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    if let Some(channel_id) = params.channel_id {
        let conversation_kind = db::groups::get_conversation_kind(&state.pool, conversation_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in get_messages/get_conversation_kind: {e:?}");
                AppError::internal("Database error")
            })?
            .ok_or_else(|| AppError::bad_request("Conversation not found"))?;

        if ConversationKind::from_str_opt(&conversation_kind) != Some(ConversationKind::Group) {
            return Err(AppError::bad_request(
                "channel_id is only supported for group conversations",
            ));
        }

        let channel = db::channels::get_channel(&state.pool, channel_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in get_messages/get_channel: {e:?}");
                AppError::internal("Database error")
            })?
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
    .map_err(|e| {
        tracing::error!("DB error in get_messages/fetch: {e:?}");
        AppError::internal("Database error")
    })?;

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
        .map_err(|e| {
            tracing::error!("DB error in create_dm/are_contacts: {e:?}");
            AppError::internal("Database error")
        })?;
    if !are_contacts {
        return Err(AppError::bad_request("Not a contact"));
    }
    let conversation_id =
        db::messages::find_or_create_dm_conversation(&state.pool, auth.user_id, req.peer_user_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in create_dm/find_or_create: {e:?}");
                AppError::internal("Failed to create conversation")
            })?;
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
        .map_err(|e| {
            tracing::error!("DB error in delete_message: {e:?}");
            AppError::internal("Database error")
        })?
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
        state.hub.broadcast_json(&member_ids, &json, None);
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
            .map_err(|e| {
                tracing::error!("DB error in edit_message: {e:?}");
                AppError::internal("Database error")
            })?
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
        state.hub.broadcast_json(&member_ids, &json, None);
    }

    Ok(Json(serde_json::json!({
        "message_id": message_id,
        "edited_at": edited_at,
    })))
}

// ---------------------------------------------------------------------------
// GET /api/conversations/:conversation_id/search -- full-text message search
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub q: String,
    #[serde(default = "default_search_limit")]
    pub limit: i64,
}

fn default_search_limit() -> i64 {
    20
}

pub async fn search_messages(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
    Query(params): Query<SearchQuery>,
) -> Result<impl IntoResponse, AppError> {
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in search_messages/is_member: {e:?}");
            AppError::internal("Database error")
        })?;
    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    let messages = db::messages::search_messages(
        &state.pool,
        conversation_id,
        &params.q,
        params.limit.min(50),
    )
    .await
    .map_err(|e| {
        tracing::error!("DB error in search_messages: {e:?}");
        AppError::internal("Search failed")
    })?;

    Ok(Json(messages))
}

// ---------------------------------------------------------------------------
// GET /api/messages/search?q=<query>&limit=20 -- global full-text search
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct GlobalSearchQuery {
    pub q: String,
    #[serde(default = "default_search_limit")]
    pub limit: i64,
}

pub async fn search_messages_global(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Query(params): Query<GlobalSearchQuery>,
) -> Result<impl IntoResponse, AppError> {
    let q = params.q.trim();
    if q.is_empty() {
        return Err(AppError::bad_request("Search query cannot be empty"));
    }

    let limit = params.limit.clamp(1, 50);

    let results = db::messages::search_messages_global(&state.pool, auth.user_id, q, limit)
        .await
        .map_err(|e| {
            tracing::error!("DB error in search_messages_global: {e:?}");
            AppError::internal("Search failed")
        })?;

    Ok(Json(results))
}

// ---------------------------------------------------------------------------
// POST /api/conversations/:conversation_id/leave -- leave/delete a conversation
// ---------------------------------------------------------------------------

pub async fn leave_conversation(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let removed = db::groups::remove_member(&state.pool, conversation_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in leave_conversation: {e:?}");
            AppError::internal("Failed to leave conversation")
        })?;

    if !removed {
        return Err(AppError::bad_request("Not a member of this conversation"));
    }

    Ok(StatusCode::OK)
}

// ---------------------------------------------------------------------------
// PUT /api/conversations/:conversation_id/mute -- toggle mute
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ToggleMuteRequest {
    pub is_muted: bool,
}

pub async fn toggle_mute(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
    Json(body): Json<ToggleMuteRequest>,
) -> Result<impl IntoResponse, AppError> {
    let updated =
        db::messages::set_mute_status(&state.pool, conversation_id, auth.user_id, body.is_muted)
            .await
            .map_err(|e| {
                tracing::error!("DB error in toggle_mute: {e:?}");
                AppError::internal("Database error")
            })?;

    if !updated {
        return Err(AppError::bad_request("Not a member of this conversation"));
    }

    Ok(Json(serde_json::json!({
        "conversation_id": conversation_id,
        "is_muted": body.is_muted,
    })))
}

// ---------------------------------------------------------------------------
// POST /api/conversations/:conversation_id/messages/:message_id/pin
// ---------------------------------------------------------------------------

pub async fn pin_message(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((conversation_id, message_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    // Verify membership
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in pin_message/is_member: {e:?}");
            AppError::internal("Database error")
        })?;
    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    // For groups, only admins/owners can pin
    let kind = db::groups::get_conversation_kind(&state.pool, conversation_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in pin_message/get_kind: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("Conversation not found"))?;

    if ConversationKind::from_str_opt(&kind) == Some(ConversationKind::Group) {
        let role_str = db::groups::get_member_role(&state.pool, conversation_id, auth.user_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in pin_message/get_role: {e:?}");
                AppError::internal("Database error")
            })?
            .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

        let role = Role::from_str_opt(&role_str).unwrap_or(Role::Member);
        if !role.is_admin_or_above() {
            return Err(AppError::unauthorized(
                "Only admins and owners can pin messages in groups",
            ));
        }
    }

    // Pin the message (atomically verified against the correct conversation)
    let _conv_id =
        db::messages::pin_message(&state.pool, message_id, auth.user_id, conversation_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in pin_message: {e:?}");
                AppError::internal("Database error")
            })?
            .ok_or_else(|| {
                AppError::bad_request("Message not found or does not belong to this conversation")
            })?;

    // Look up pinner's username for the broadcast event
    let pinner = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in pin_message/find_user: {e:?}");
            AppError::internal("Database error")
        })?;
    let pinned_by_username = pinner
        .map(|u| u.username)
        .unwrap_or_else(|| "unknown".to_string());

    // Broadcast to conversation members via WebSocket
    let member_ids = db::groups::get_conversation_member_ids(&state.pool, conversation_id)
        .await
        .unwrap_or_default();

    let event = serde_json::json!({
        "type": "message_pinned",
        "message_id": message_id,
        "conversation_id": conversation_id,
        "pinned_by_id": auth.user_id,
        "pinned_by_username": pinned_by_username,
        "pinned_at": chrono::Utc::now(),
    });
    if let Ok(json) = serde_json::to_string(&event) {
        state.hub.broadcast_json(&member_ids, &json, None);
    }

    Ok(Json(serde_json::json!({
        "message_id": message_id,
        "conversation_id": conversation_id,
        "pinned_by_id": auth.user_id,
    })))
}

// ---------------------------------------------------------------------------
// DELETE /api/conversations/:conversation_id/messages/:message_id/pin
// ---------------------------------------------------------------------------

pub async fn unpin_message(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((conversation_id, message_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    // Verify membership
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in unpin_message/is_member: {e:?}");
            AppError::internal("Database error")
        })?;
    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    // For groups, only admins/owners can unpin
    let kind = db::groups::get_conversation_kind(&state.pool, conversation_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in unpin_message/get_kind: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("Conversation not found"))?;

    if ConversationKind::from_str_opt(&kind) == Some(ConversationKind::Group) {
        let role_str = db::groups::get_member_role(&state.pool, conversation_id, auth.user_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in unpin_message/get_role: {e:?}");
                AppError::internal("Database error")
            })?
            .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

        let role = Role::from_str_opt(&role_str).unwrap_or(Role::Member);
        if !role.is_admin_or_above() {
            return Err(AppError::unauthorized(
                "Only admins and owners can unpin messages in groups",
            ));
        }
    }

    // Unpin the message
    let conv_id = db::messages::unpin_message(&state.pool, message_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in unpin_message: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("Message not found or not pinned"))?;

    if conv_id != conversation_id {
        return Err(AppError::bad_request(
            "Message does not belong to this conversation",
        ));
    }

    // Broadcast to conversation members via WebSocket
    let member_ids = db::groups::get_conversation_member_ids(&state.pool, conversation_id)
        .await
        .unwrap_or_default();

    let event = serde_json::json!({
        "type": "message_unpinned",
        "message_id": message_id,
        "conversation_id": conversation_id,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        state.hub.broadcast_json(&member_ids, &json, None);
    }

    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// GET /api/conversations/:conversation_id/pinned
// ---------------------------------------------------------------------------

pub async fn get_pinned_messages(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Verify membership
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_pinned_messages/is_member: {e:?}");
            AppError::internal("Database error")
        })?;
    if !is_member {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    let pinned = db::messages::get_pinned_messages(&state.pool, conversation_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_pinned_messages: {e:?}");
            AppError::internal("Database error")
        })?;

    Ok(Json(pinned))
}
