//! Contact management endpoints.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::Deserialize;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateContactRequest {
    pub username: String,
}

#[derive(Debug, Deserialize)]
pub struct AcceptContactRequest {
    pub contact_id: Uuid,
}

pub async fn send_request(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<CreateContactRequest>,
) -> Result<impl IntoResponse, AppError> {
    let contact_id =
        db::contacts::create_contact_request(&state.pool, auth.user_id, &body.username)
            .await
            .map_err(|e| {
                match &e {
                    sqlx::Error::RowNotFound => {
                        tracing::debug!(
                            "Contact request failed (user not found): {}",
                            &body.username
                        );
                    }
                    sqlx::Error::Database(db_err) if db_err.code().as_deref() == Some("23505") => {
                        tracing::debug!("Contact request failed (duplicate): {}", &body.username);
                    }
                    _ => {
                        tracing::error!("Contact request database error: {:?}", e);
                    }
                }
                AppError::bad_request("Could not send contact request")
            })?;

    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({ "contact_id": contact_id })),
    ))
}

pub async fn accept_request(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<AcceptContactRequest>,
) -> Result<impl IntoResponse, AppError> {
    db::contacts::accept_contact_request(&state.pool, body.contact_id, auth.user_id)
        .await
        .map_err(|e| match e {
            sqlx::Error::RowNotFound => AppError::bad_request("No pending request found"),
            _ => AppError::internal("Database error"),
        })?;

    Ok(Json(serde_json::json!({ "status": "accepted" })))
}

pub async fn list_contacts(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    let contacts = db::contacts::list_contacts(&state.pool, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok(Json(contacts))
}

pub async fn list_pending(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    let pending = db::contacts::list_pending_requests(&state.pool, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok(Json(pending))
}

// ---------------------------------------------------------------------------
// Block / unblock
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct BlockRequest {
    pub user_id: Uuid,
}

pub async fn block_user(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<BlockRequest>,
) -> Result<impl IntoResponse, AppError> {
    if body.user_id == auth.user_id {
        return Err(AppError::bad_request("Cannot block yourself"));
    }

    db::contacts::block_user(&state.pool, auth.user_id, body.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({ "status": "blocked" })),
    ))
}

pub async fn unblock_user(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<BlockRequest>,
) -> Result<impl IntoResponse, AppError> {
    let removed = db::contacts::unblock_user(&state.pool, auth.user_id, body.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if !removed {
        return Err(AppError::bad_request("User is not blocked"));
    }

    Ok(Json(serde_json::json!({ "status": "unblocked" })))
}

pub async fn list_blocked(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    let blocked = db::contacts::list_blocked_users(&state.pool, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok(Json(blocked))
}
