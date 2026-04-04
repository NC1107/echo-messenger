//! Authentication endpoints: register, login, refresh, logout, ws-ticket.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::middleware::AuthUser;
use crate::auth::{jwt, password};
use crate::db;
use crate::error::AppError;

use super::AppState;

// ---------------------------------------------------------------------------
// Request / response types
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct AuthRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub user_id: String,
    pub access_token: String,
    pub refresh_token: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

#[derive(Debug, Serialize)]
pub struct RefreshResponse {
    pub access_token: String,
    pub refresh_token: String,
}

#[derive(Debug, Serialize)]
pub struct WsTicketResponse {
    pub ticket: String,
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

fn validate_username(username: &str) -> Result<(), AppError> {
    if username.len() < 3 || username.len() > 32 {
        return Err(AppError::bad_request(
            "Username must be between 3 and 32 characters",
        ));
    }
    if !username
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return Err(AppError::bad_request(
            "Username must contain only alphanumeric characters and underscores",
        ));
    }
    Ok(())
}

fn validate_password(password: &str) -> Result<(), AppError> {
    if password.len() < 8 {
        return Err(AppError::bad_request(
            "Password must be at least 8 characters",
        ));
    }
    if password.len() > 128 {
        return Err(AppError::bad_request(
            "Password must be at most 128 characters",
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Refresh token helper (issue + persist)
// ---------------------------------------------------------------------------

async fn issue_refresh_token(pool: &sqlx::PgPool, user_id: uuid::Uuid) -> Result<String, AppError> {
    let raw_token = jwt::create_refresh_token();
    let token_hash = jwt::hash_refresh_token(&raw_token);
    let expires_at = chrono::Utc::now() + chrono::Duration::days(7);
    db::tokens::store_refresh_token(pool, user_id, &token_hash, expires_at).await?;
    Ok(raw_token)
}

// ---------------------------------------------------------------------------
// POST /api/auth/register
// ---------------------------------------------------------------------------

pub async fn register(
    State(state): State<Arc<AppState>>,
    Json(body): Json<AuthRequest>,
) -> Result<impl IntoResponse, AppError> {
    validate_username(&body.username)?;
    validate_password(&body.password)?;

    let password_hash = password::hash_password(&body.password)?;
    let user_id = db::users::create_user(&state.pool, &body.username, &password_hash).await?;
    let access_token = jwt::create_token(user_id, &state.jwt_secret)?;
    let refresh_token = issue_refresh_token(&state.pool, user_id).await?;

    let response = AuthResponse {
        user_id: user_id.to_string(),
        access_token,
        refresh_token,
        avatar_url: None,
    };

    Ok((StatusCode::CREATED, Json(response)))
}

// ---------------------------------------------------------------------------
// POST /api/auth/login
// ---------------------------------------------------------------------------

pub async fn login(
    State(state): State<Arc<AppState>>,
    Json(body): Json<AuthRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = db::users::find_by_username(&state.pool, &body.username)
        .await?
        .ok_or_else(|| AppError::unauthorized("Invalid username or password"))?;

    let valid = password::verify_password(&body.password, &user.password_hash)?;
    if !valid {
        return Err(AppError::unauthorized("Invalid username or password"));
    }

    let access_token = jwt::create_token(user.id, &state.jwt_secret)?;
    let refresh_token = issue_refresh_token(&state.pool, user.id).await?;

    let response = AuthResponse {
        user_id: user.id.to_string(),
        access_token,
        refresh_token,
        avatar_url: user.avatar_url,
    };

    Ok(Json(response))
}

// ---------------------------------------------------------------------------
// POST /api/auth/refresh
// ---------------------------------------------------------------------------

pub async fn refresh(
    State(state): State<Arc<AppState>>,
    Json(body): Json<RefreshRequest>,
) -> Result<impl IntoResponse, AppError> {
    let token_hash = jwt::hash_refresh_token(&body.refresh_token);

    let row = db::tokens::find_refresh_token(&state.pool, &token_hash)
        .await?
        .ok_or_else(|| AppError::unauthorized("Invalid refresh token"))?;

    if row.revoked {
        return Err(AppError::unauthorized("Refresh token has been revoked"));
    }

    if row.expires_at < chrono::Utc::now() {
        return Err(AppError::unauthorized("Refresh token has expired"));
    }

    // Rotate: revoke old, issue new
    db::tokens::revoke_refresh_token(&state.pool, row.id).await?;

    let access_token = jwt::create_token(row.user_id, &state.jwt_secret)?;
    let new_refresh = issue_refresh_token(&state.pool, row.user_id).await?;

    Ok(Json(RefreshResponse {
        access_token,
        refresh_token: new_refresh,
    }))
}

// ---------------------------------------------------------------------------
// POST /api/auth/logout
// ---------------------------------------------------------------------------

pub async fn logout(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
) -> Result<impl IntoResponse, AppError> {
    db::tokens::revoke_all_user_tokens(&state.pool, auth_user.user_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// POST /api/auth/ws-ticket
// ---------------------------------------------------------------------------

pub async fn ws_ticket(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
) -> Result<impl IntoResponse, AppError> {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use rand::RngCore;
    use std::time::{Duration, Instant};

    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    let ticket = URL_SAFE_NO_PAD.encode(bytes);

    const TICKET_TTL: Duration = Duration::from_secs(30);
    const MAX_TICKETS: usize = 10_000;

    let mut store = state
        .ticket_store
        .lock()
        .map_err(|_| AppError::internal("Internal state error"))?;

    // Clean up expired tickets to bound memory
    let now = Instant::now();
    store.retain(|_, (_, ts)| now.duration_since(*ts) < TICKET_TTL);

    // Cap total tickets to prevent memory exhaustion
    if store.len() >= MAX_TICKETS {
        return Err(AppError::bad_request(
            "Too many pending tickets, try again later",
        ));
    }

    store.insert(ticket.clone(), (auth_user.user_id, now));
    drop(store);

    Ok(Json(WsTicketResponse { ticket }))
}
