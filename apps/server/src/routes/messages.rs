//! Message and conversation REST endpoints.

use axum::Json;
use axum::extract::{Path, Query, State};
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

#[derive(Debug, Serialize)]
pub struct MemberInfo {
    pub user_id: Uuid,
    pub username: String,
}

#[derive(Debug, Serialize)]
pub struct LastMessageInfo {
    pub content: String,
    pub sender_username: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, sqlx::FromRow)]
struct ConversationRow {
    conversation_id: Uuid,
    kind: String,
    title: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct LastMessageRow {
    content: String,
    sender_username: String,
    created_at: DateTime<Utc>,
}

pub async fn list_conversations(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    // Get all conversations the user is a member of
    let conversations = sqlx::query_as::<_, ConversationRow>(
        "SELECT c.id AS conversation_id, c.kind, c.title \
         FROM conversations c \
         JOIN conversation_members cm ON cm.conversation_id = c.id \
         WHERE cm.user_id = $1 \
         ORDER BY c.created_at DESC",
    )
    .bind(auth.user_id)
    .fetch_all(&state.pool)
    .await
    .map_err(|_| AppError::internal("Database error"))?;

    let mut result = Vec::with_capacity(conversations.len());

    for conv in conversations {
        // Get members
        let members = db::groups::get_group_members(&state.pool, conv.conversation_id)
            .await
            .map_err(|_| AppError::internal("Database error"))?;

        let member_infos: Vec<MemberInfo> = members
            .into_iter()
            .map(|m| MemberInfo {
                user_id: m.user_id,
                username: m.username,
            })
            .collect();

        // Get last message
        let last_message = sqlx::query_as::<_, LastMessageRow>(
            "SELECT m.content, u.username AS sender_username, m.created_at \
             FROM messages m \
             JOIN users u ON u.id = m.sender_id \
             WHERE m.conversation_id = $1 \
             ORDER BY m.created_at DESC \
             LIMIT 1",
        )
        .bind(conv.conversation_id)
        .fetch_optional(&state.pool)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

        // Get unread count
        let unread_count =
            db::reactions::get_unread_count(&state.pool, conv.conversation_id, auth.user_id)
                .await
                .unwrap_or(0);

        result.push(ConversationListItem {
            conversation_id: conv.conversation_id,
            kind: conv.kind,
            title: conv.title,
            members: member_infos,
            last_message: last_message.map(|lm| LastMessageInfo {
                content: lm.content,
                sender_username: lm.sender_username,
                created_at: lm.created_at,
            }),
            unread_count,
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
