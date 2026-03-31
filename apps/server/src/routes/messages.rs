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

#[derive(Debug, sqlx::FromRow, Serialize)]
pub struct ConversationInfo {
    pub conversation_id: Uuid,
    pub peer_user_id: Uuid,
    pub peer_username: String,
}

#[derive(Debug, Deserialize)]
pub struct MessageQuery {
    pub before: Option<DateTime<Utc>>,
    pub limit: Option<i64>,
}

pub async fn list_conversations(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    // Get all conversations the user is a member of, with the peer info
    let conversations = sqlx::query_as::<_, ConversationInfo>(
        "SELECT cm1.conversation_id, cm2.user_id AS peer_user_id, u.username AS peer_username \
         FROM conversation_members cm1 \
         JOIN conversation_members cm2 ON cm1.conversation_id = cm2.conversation_id AND cm2.user_id != $1 \
         JOIN users u ON u.id = cm2.user_id \
         WHERE cm1.user_id = $1 \
         ORDER BY cm1.conversation_id",
    )
    .bind(auth.user_id)
    .fetch_all(&state.pool)
    .await
    .map_err(|_| AppError::internal("Database error"))?;

    Ok(Json(conversations))
}

pub async fn get_messages(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(conversation_id): Path<Uuid>,
    Query(params): Query<MessageQuery>,
) -> Result<impl IntoResponse, AppError> {
    // Verify the user is a member of this conversation
    let is_member: (bool,) = sqlx::query_as(
        "SELECT EXISTS(SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2)",
    )
    .bind(conversation_id)
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| AppError::internal("Database error"))?;

    if !is_member.0 {
        return Err(AppError::unauthorized("Not a member of this conversation"));
    }

    let limit = params.limit.unwrap_or(50).min(100);
    let messages = db::messages::get_messages(&state.pool, conversation_id, params.before, limit)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok(Json(messages))
}
