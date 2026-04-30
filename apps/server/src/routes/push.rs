//! Push notification token registration endpoints.

use axum::Json;
use axum::extract::State;
use axum::response::IntoResponse;
use serde::Deserialize;
use std::sync::Arc;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;
use crate::routes::AppState;

#[derive(Deserialize)]
pub struct RegisterTokenRequest {
    pub token: String,
    pub platform: String,
}

/// Register a push notification token for the authenticated user.
/// POST /api/push/register
pub async fn register_token(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(body): Json<RegisterTokenRequest>,
) -> Result<impl IntoResponse, AppError> {
    if body.token.is_empty() {
        return Err(AppError::bad_request("Token is required"));
    }

    let platform = body.platform.to_lowercase();
    if platform != "apns" {
        return Err(AppError::bad_request(
            "Only 'apns' platform is supported (Android/desktop use persistent WebSocket)",
        ));
    }

    db::push_tokens::upsert_token(&state.pool, auth_user.user_id, &body.token, &platform).await?;

    Ok(Json(serde_json::json!({ "status": "ok" })))
}

#[derive(Deserialize)]
pub struct UnregisterTokenRequest {
    pub token: String,
}

/// Remove a push notification token (e.g. on logout).
/// POST /api/push/unregister
pub async fn unregister_token(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(body): Json<UnregisterTokenRequest>,
) -> Result<impl IntoResponse, AppError> {
    db::push_tokens::remove_token(&state.pool, auth_user.user_id, &body.token).await?;
    Ok(Json(serde_json::json!({ "status": "ok" })))
}

/// Delete every push token bound to the caller. Used when the client switches
/// servers and wants to fully detach itself from the old origin without
/// having to remember individual device tokens. Idempotent.
/// DELETE /api/push/token
pub async fn delete_all_tokens(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
) -> Result<impl IntoResponse, AppError> {
    db::push_tokens::remove_all_tokens(&state.pool, auth_user.user_id).await?;
    Ok(Json(serde_json::json!({ "status": "ok" })))
}
