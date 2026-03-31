//! Contact management endpoints.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
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
            .map_err(|e| match e {
                sqlx::Error::RowNotFound => AppError::bad_request("User not found"),
                sqlx::Error::Database(ref db_err) if db_err.code().as_deref() == Some("23505") => {
                    AppError::conflict("Contact request already exists")
                }
                _ => AppError::internal("Database error"),
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
