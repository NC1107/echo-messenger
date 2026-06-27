//! REST endpoints for the polls-in-chat MVP.
//!
//! Routes (all gated on conversation membership):
//!
//!   POST /api/messages/:id/poll
//!       body: { "question": "...", "options": ["A", "B", "C"] }
//!       Creates a poll attached to message `:id`.  Returns 201 on success,
//!       409 when a poll already exists for that message.
//!
//!   POST /api/messages/:id/poll/vote
//!       body: { "option_index": N }
//!       Records the caller's vote (upserts — the caller can change their mind).
//!
//!   GET /api/messages/:id/poll
//!       Returns { question, options: [{text, count, voters}], my_vote }.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::Deserialize;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx};

use super::AppState;

// ---------------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreatePollRequest {
    pub question: String,
    pub options: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct VoteRequest {
    pub option_index: i32,
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// POST /api/messages/:id/poll — attach a poll to an existing message.
pub async fn create_poll(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(message_id): Path<Uuid>,
    Json(body): Json<CreatePollRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Basic validation.
    if body.question.trim().is_empty() {
        return Err(AppError::bad_request("Poll question must not be empty"));
    }
    if body.options.len() < 2 {
        return Err(AppError::bad_request("A poll needs at least 2 options"));
    }
    if body.options.len() > 10 {
        return Err(AppError::bad_request("A poll may have at most 10 options"));
    }
    for opt in &body.options {
        if opt.trim().is_empty() {
            return Err(AppError::bad_request("Poll options must not be blank"));
        }
    }

    // Verify message exists and resolve conversation.
    let conversation_id = db::reactions::get_message_conversation_id(&state.pool, message_id)
        .await
        .db_ctx("create_poll/get_conversation")?
        .ok_or_else(|| AppError::not_found("Message not found"))?;

    // Membership check.
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .db_ctx("create_poll/is_member")?;
    if !is_member {
        return Err(AppError::forbidden("Not a member of this conversation"));
    }

    // Reject duplicate polls.
    let exists = db::polls::poll_exists(&state.pool, message_id)
        .await
        .db_ctx("create_poll/poll_exists")?;
    if exists {
        return Err(AppError::conflict("A poll already exists for this message"));
    }

    db::polls::create_poll(&state.pool, message_id, &body.question, &body.options)
        .await
        .db_ctx("create_poll/insert")?;

    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({ "message_id": message_id })),
    ))
}

/// POST /api/messages/:id/poll/vote — record the caller's vote.
pub async fn vote_poll(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(message_id): Path<Uuid>,
    Json(body): Json<VoteRequest>,
) -> Result<impl IntoResponse, AppError> {
    if body.option_index < 0 {
        return Err(AppError::bad_request("option_index must be non-negative"));
    }

    // Resolve conversation.
    let conversation_id = db::reactions::get_message_conversation_id(&state.pool, message_id)
        .await
        .db_ctx("vote_poll/get_conversation")?
        .ok_or_else(|| AppError::not_found("Message not found"))?;

    // Membership check.
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .db_ctx("vote_poll/is_member")?;
    if !is_member {
        return Err(AppError::forbidden("Not a member of this conversation"));
    }

    // Bounds-check the option index against the stored options.
    let n = db::polls::option_count(&state.pool, message_id)
        .await
        .db_ctx("vote_poll/option_count")?
        .ok_or_else(|| AppError::not_found("No poll found for this message"))?;

    if body.option_index as usize >= n {
        return Err(AppError::bad_request("option_index out of range"));
    }

    db::polls::upsert_vote(&state.pool, message_id, auth.user_id, body.option_index)
        .await
        .db_ctx("vote_poll/upsert")?;

    Ok(Json(serde_json::json!({ "status": "voted" })))
}

/// GET /api/messages/:id/poll — fetch poll results.
pub async fn get_poll(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(message_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Resolve conversation.
    let conversation_id = db::reactions::get_message_conversation_id(&state.pool, message_id)
        .await
        .db_ctx("get_poll/get_conversation")?
        .ok_or_else(|| AppError::not_found("Message not found"))?;

    // Membership check.
    let is_member = db::groups::is_member(&state.pool, conversation_id, auth.user_id)
        .await
        .db_ctx("get_poll/is_member")?;
    if !is_member {
        return Err(AppError::forbidden("Not a member of this conversation"));
    }

    let result = db::polls::get_poll(&state.pool, message_id, auth.user_id)
        .await
        .db_ctx("get_poll/query")?
        .ok_or_else(|| AppError::not_found("No poll found for this message"))?;

    Ok(Json(result))
}
