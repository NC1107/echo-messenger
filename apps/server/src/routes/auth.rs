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

/// Issue a new refresh token with a new family (used on login/register).
async fn issue_refresh_token(
    pool: &sqlx::PgPool,
    user_id: uuid::Uuid,
) -> Result<(String, uuid::Uuid), AppError> {
    let raw_token = jwt::create_refresh_token();
    let token_hash = jwt::hash_refresh_token(&raw_token);
    let expires_at = chrono::Utc::now() + chrono::Duration::days(7);
    let family_id = db::tokens::store_refresh_token(pool, user_id, &token_hash, expires_at).await?;
    Ok((raw_token, family_id))
}

/// Issue a refresh token that inherits an existing family (used on rotation).
async fn rotate_refresh_token(
    pool: &sqlx::PgPool,
    user_id: uuid::Uuid,
    family_id: uuid::Uuid,
) -> Result<String, AppError> {
    let raw_token = jwt::create_refresh_token();
    let token_hash = jwt::hash_refresh_token(&raw_token);
    let expires_at = chrono::Utc::now() + chrono::Duration::days(7);
    db::tokens::store_refresh_token_in_family(pool, user_id, &token_hash, expires_at, family_id)
        .await?;
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

    let pw = body.password.clone();
    let password_hash = tokio::task::spawn_blocking(move || password::hash_password(&pw))
        .await
        .map_err(|_| AppError::internal("Password hashing failed"))??;
    let user_id = db::users::create_user(&state.pool, &body.username, &password_hash).await?;
    let access_token = jwt::create_token(user_id, &state.jwt_secret)?;
    let (refresh_token, _family_id) = issue_refresh_token(&state.pool, user_id).await?;

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
    // Pre-computed Argon2id hash of a random string. Used when the requested
    // user does not exist so that the response latency is indistinguishable
    // from a wrong-password attempt (prevents username enumeration via timing).
    // The 32-byte output (43 base64 chars) matches Argon2::default() output
    // length to avoid measurable timing differences in the finalization pass.
    const DUMMY_HASH: &str =
        "$argon2id$v=19$m=19456,t=2,p=1$bm9uZXhpc3RlbnQ$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    let maybe_user = db::users::find_by_username(&state.pool, &body.username).await?;

    let hash = match &maybe_user {
        Some(u) => u.password_hash.clone(),
        None => DUMMY_HASH.to_string(),
    };

    let pw = body.password.clone();
    let valid = tokio::task::spawn_blocking(move || password::verify_password(&pw, &hash))
        .await
        .map_err(|_| AppError::internal("Password verification failed"))??;

    let user = match maybe_user {
        Some(u) if valid => u,
        _ => return Err(AppError::unauthorized("Invalid username or password")),
    };

    let access_token = jwt::create_token(user.id, &state.jwt_secret)?;
    let (refresh_token, _family_id) = issue_refresh_token(&state.pool, user.id).await?;

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
        // TOKEN THEFT DETECTED: a revoked token was reused.  The attacker
        // (or the legitimate user) still holds a token from this family.
        // Revoke the entire family to force re-authentication for everyone.
        if let Some(family_id) = row.family_id {
            tracing::warn!(
                "Refresh token theft detected for user {} (family {})",
                row.user_id,
                family_id
            );
            db::tokens::revoke_token_family(&state.pool, family_id).await?;
        }
        return Err(AppError::unauthorized("Refresh token has been revoked"));
    }

    if row.expires_at < chrono::Utc::now() {
        return Err(AppError::unauthorized("Refresh token has expired"));
    }

    // Rotate: revoke old, issue new in the same family
    db::tokens::revoke_refresh_token(&state.pool, row.id).await?;

    let family_id = row.family_id.unwrap_or_else(uuid::Uuid::new_v4);
    let access_token = jwt::create_token(row.user_id, &state.jwt_secret)?;
    let new_refresh = rotate_refresh_token(&state.pool, row.user_id, family_id).await?;

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

/// Optional device_id in ws-ticket request body.
#[derive(Debug, Deserialize, Default)]
pub struct WsTicketRequest {
    #[serde(default)]
    pub device_id: i32,
}

pub async fn ws_ticket(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    body: Option<Json<WsTicketRequest>>,
) -> Result<impl IntoResponse, AppError> {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use rand::RngCore;
    use std::time::{Duration, Instant};

    let device_id = body.map(|b| b.device_id).unwrap_or(0);

    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    let ticket = URL_SAFE_NO_PAD.encode(bytes);

    const TICKET_TTL: Duration = Duration::from_secs(30);
    const MAX_TICKETS: usize = 10_000;

    // Clean up expired tickets to bound memory
    let now = Instant::now();
    state
        .ticket_store
        .retain(|_, (_, _, ts)| now.duration_since(*ts) < TICKET_TTL);

    // Cap total tickets to prevent memory exhaustion
    if state.ticket_store.len() >= MAX_TICKETS {
        return Err(AppError::bad_request(
            "Too many pending tickets, try again later",
        ));
    }

    state
        .ticket_store
        .insert(ticket.clone(), (auth_user.user_id, device_id, now));

    Ok(Json(WsTicketResponse { ticket }))
}
