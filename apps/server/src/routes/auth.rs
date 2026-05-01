//! Authentication endpoints: register, login, refresh, logout, ws-ticket,
//! forgot-password, reset-password.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::middleware::AuthUser;
use crate::auth::{jwt, password};
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};

use super::AppState;

// ---------------------------------------------------------------------------
// Refresh token cookie helpers (#342)
//
// The web client stores the refresh token in an HttpOnly + Secure +
// SameSite=Strict cookie scoped to `/api/auth`. Mobile/desktop continue to
// receive the token in the JSON body for backward compatibility. `/refresh`
// accepts either; cookie wins when both are present.
// ---------------------------------------------------------------------------

const REFRESH_COOKIE_NAME: &str = "echo_refresh";
const REFRESH_COOKIE_MAX_AGE_SECS: i64 = 7 * 24 * 60 * 60;

fn build_refresh_cookie(value: String) -> Cookie<'static> {
    Cookie::build((REFRESH_COOKIE_NAME, value))
        .http_only(true)
        .secure(true)
        .same_site(SameSite::Strict)
        .path("/api/auth")
        .max_age(time::Duration::seconds(REFRESH_COOKIE_MAX_AGE_SECS))
        .build()
}

fn clear_refresh_cookie() -> Cookie<'static> {
    Cookie::build((REFRESH_COOKIE_NAME, ""))
        .http_only(true)
        .secure(true)
        .same_site(SameSite::Strict)
        .path("/api/auth")
        .max_age(time::Duration::ZERO)
        .build()
}

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

#[derive(Debug, Deserialize, Default)]
pub struct RefreshRequest {
    #[serde(default)]
    pub refresh_token: Option<String>,
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

// ---------------------------------------------------------------------------
// POST /api/auth/register
// ---------------------------------------------------------------------------

pub async fn register(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Json(body): Json<AuthRequest>,
) -> Result<impl IntoResponse, AppError> {
    if !crate::config::registration_open() {
        return Err(AppError::with_code(
            ErrorCode::RegistrationDisabled,
            "Registration is closed on this server",
        ));
    }

    validate_username(&body.username)?;
    validate_password(&body.password)?;

    let pw = body.password.clone();
    let password_hash = tokio::task::spawn_blocking(move || password::hash_password(&pw))
        .await
        .map_err(|_| AppError::internal("Password hashing failed"))??;
    let user_id = db::users::create_user(&state.pool, &body.username, &password_hash).await?;
    let access_token = jwt::create_token(user_id, &state.jwt_secret)?;
    let (refresh_token, _family_id) = issue_refresh_token(&state.pool, user_id).await?;

    // Web clients consume the cookie; mobile/desktop still read the JSON body.
    let jar = jar.add(build_refresh_cookie(refresh_token.clone()));

    let response = AuthResponse {
        user_id: user_id.to_string(),
        access_token,
        refresh_token,
        avatar_url: None,
    };

    Ok((StatusCode::CREATED, jar, Json(response)))
}

// ---------------------------------------------------------------------------
// POST /api/auth/login
// ---------------------------------------------------------------------------

pub async fn login(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Json(body): Json<AuthRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Pre-computed Argon2id hash of a random string. Used when the requested
    // user does not exist so that the response latency is indistinguishable
    // from a wrong-password attempt (prevents username enumeration via timing).
    // The 32-byte output (43 base64 chars) matches Argon2::default() output
    // length to avoid measurable timing differences in the finalization pass.
    const DUMMY_HASH: &str = "$argon2id$v=19$m=19456,t=2,p=1$bm9uZXhpc3RlbnQ$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

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
        _ => {
            return Err(AppError::with_code(
                ErrorCode::WrongPassword,
                "Invalid username or password",
            ));
        }
    };

    let access_token = jwt::create_token(user.id, &state.jwt_secret)?;
    let (refresh_token, _family_id) = issue_refresh_token(&state.pool, user.id).await?;

    let jar = jar.add(build_refresh_cookie(refresh_token.clone()));

    let response = AuthResponse {
        user_id: user.id.to_string(),
        access_token,
        refresh_token,
        avatar_url: user.avatar_url,
    };

    Ok((jar, Json(response)))
}

// ---------------------------------------------------------------------------
// POST /api/auth/refresh
// ---------------------------------------------------------------------------

/// Atomically validate and rotate a refresh token. #520
///
/// The whole flow — SELECT (with row lock), revoke-old, INSERT-new — runs in a
/// single transaction so two concurrent requests presenting the same refresh
/// token cannot both succeed.  The first to reach the sentinel UPDATE wins;
/// the second gets `None` from the conditional UPDATE, treats it as
/// concurrent reuse, family-revokes, and returns 401.  This prevents the race
/// where both callers observed `revoked = false` in the old non-transactional
/// code path.
pub async fn refresh(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    body: Option<Json<RefreshRequest>>,
) -> Result<impl IntoResponse, AppError> {
    // Cookie wins when both are present so the web client's HttpOnly cookie
    // can never be silently overridden by a malicious JSON body. Mobile/desktop
    // clients keep sending the token in the body and that path still works.
    let cookie_token = jar
        .get(REFRESH_COOKIE_NAME)
        .map(|c| c.value().to_string())
        .filter(|s| !s.is_empty());
    let body_token = body
        .and_then(|Json(b)| b.refresh_token)
        .filter(|s| !s.is_empty());
    let raw_token = cookie_token
        .or(body_token)
        .ok_or_else(|| AppError::unauthorized("Missing refresh token"))?;

    let token_hash = jwt::hash_refresh_token(&raw_token);

    let mut tx = state.pool.begin().await.db_ctx("refresh/begin_tx")?;

    // Lock the refresh-token row for the duration of the transaction so a
    // concurrent rotation request must wait until we commit (or rolls back).
    let row: Option<db::tokens::RefreshTokenRow> =
        sqlx::query_as::<_, db::tokens::RefreshTokenRow>(
            "SELECT id, user_id, token_hash, expires_at, created_at, revoked, family_id \
         FROM refresh_tokens WHERE token_hash = $1 FOR UPDATE",
        )
        .bind(&token_hash)
        .fetch_optional(&mut *tx)
        .await
        .db_ctx("refresh/fetch_token")?;

    let Some(row) = row else {
        // Drop the (read-only) tx implicitly.
        return Err(AppError::unauthorized("Invalid refresh token"));
    };

    if row.revoked {
        // TOKEN THEFT DETECTED: a revoked token was reused.  Revoke the rest
        // of the family inside the same tx so the response is consistent.
        if let Some(family_id) = row.family_id {
            tracing::warn!(
                "Refresh token theft detected for user {} (family {})",
                row.user_id,
                family_id
            );
            sqlx::query(
                "UPDATE refresh_tokens SET revoked = true \
                 WHERE family_id = $1 AND revoked = false",
            )
            .bind(family_id)
            .execute(&mut *tx)
            .await
            .db_ctx("refresh/revoke_family_theft")?;
        }
        tx.commit().await.db_ctx("refresh/commit_theft")?;
        return Err(AppError::with_code(
            ErrorCode::TokenRevoked,
            "Refresh token has been revoked",
        ));
    }

    if row.expires_at < chrono::Utc::now() {
        // Release the FOR UPDATE row lock immediately rather than waiting for
        // tx Drop to do an implicit rollback.
        let _ = tx.rollback().await;
        return Err(AppError::with_code(
            ErrorCode::TokenExpired,
            "Refresh token has expired",
        ));
    }

    // Sentinel revoke: only one transaction can flip `revoked` from false to
    // true.  If `fetch_optional` returns `None`, another request beat us to
    // it — treat as concurrent reuse and revoke the family.
    let revoked: Option<(uuid::Uuid,)> = sqlx::query_as::<_, (uuid::Uuid,)>(
        "UPDATE refresh_tokens SET revoked = true \
         WHERE id = $1 AND revoked = false RETURNING id",
    )
    .bind(row.id)
    .fetch_optional(&mut *tx)
    .await
    .db_ctx("refresh/sentinel_revoke")?;

    if revoked.is_none() {
        if let Some(family_id) = row.family_id {
            tracing::warn!(
                "Concurrent refresh-token rotation detected for user {} (family {})",
                row.user_id,
                family_id
            );
            sqlx::query(
                "UPDATE refresh_tokens SET revoked = true \
                 WHERE family_id = $1 AND revoked = false",
            )
            .bind(family_id)
            .execute(&mut *tx)
            .await
            .db_ctx("refresh/revoke_family_concurrent")?;
        }
        tx.commit().await.db_ctx("refresh/commit_concurrent")?;
        return Err(AppError::with_code(
            ErrorCode::TokenRevoked,
            "Refresh token has been revoked",
        ));
    }

    // Issue the rotated token in the same family.
    let family_id = row.family_id.unwrap_or_else(uuid::Uuid::new_v4);
    let new_raw_token = jwt::create_refresh_token();
    let new_token_hash = jwt::hash_refresh_token(&new_raw_token);
    let new_expires_at = chrono::Utc::now() + chrono::Duration::days(7);

    sqlx::query(
        "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, family_id) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(row.user_id)
    .bind(&new_token_hash)
    .bind(new_expires_at)
    .bind(family_id)
    .execute(&mut *tx)
    .await
    .db_ctx("refresh/insert_new_token")?;

    tx.commit().await.db_ctx("refresh/commit")?;

    let access_token = jwt::create_token(row.user_id, &state.jwt_secret)?;

    let jar = jar.add(build_refresh_cookie(new_raw_token.clone()));

    Ok((
        jar,
        Json(RefreshResponse {
            access_token,
            refresh_token: new_raw_token,
        }),
    ))
}

// ---------------------------------------------------------------------------
// POST /api/auth/logout
// ---------------------------------------------------------------------------

pub async fn logout(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    auth_user: AuthUser,
) -> Result<impl IntoResponse, AppError> {
    db::tokens::revoke_all_user_tokens(&state.pool, auth_user.user_id).await?;
    let jar = jar.add(clear_refresh_cookie());
    // Convention: StatusCode first, then CookieJar, matching register/login.
    Ok((StatusCode::NO_CONTENT, jar))
}

// ---------------------------------------------------------------------------
// POST /api/auth/forgot-password
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ForgotPasswordRequest {
    pub username: String,
}

/// Always returns 200 regardless of whether the username exists.
///
/// When the user is found a single-use reset token is generated and logged
/// to stdout via `tracing::info` for admin-mediated relay. No email is sent
/// (Option A: admin-mediated, no SMTP infra yet -- #476). A follow-up issue
/// should add SMTP support for production deployments.
pub async fn forgot_password(
    State(state): State<Arc<AppState>>,
    Json(body): Json<ForgotPasswordRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Look up the user. Errors are swallowed so the response is identical
    // whether the username exists or not (prevents username enumeration).
    if let Ok(Some(user)) = db::users::find_by_username(&state.pool, &body.username).await {
        let token: String = {
            use rand::RngExt as _;
            let bytes: [u8; 32] = rand::rng().random();
            bytes
                .iter()
                .fold(String::with_capacity(64), |mut s: String, b| {
                    use std::fmt::Write as _;
                    let _ = write!(s, "{b:02x}");
                    s
                })
        };
        let expires_at = chrono::Utc::now() + chrono::Duration::minutes(15);

        if db::password_reset::create_token(&state.pool, &token, user.id, expires_at)
            .await
            .is_ok()
        {
            // Admin-mediated: log token to stdout for the operator to relay.
            // WARNING: this token grants full password reset access. Treat
            // the server logs as sensitive material and rotate promptly.
            tracing::info!(
                username = %body.username,
                user_id  = %user.id,
                token    = %token,
                expires  = %expires_at,
                "[PASSWORD RESET] Single-use reset token issued. \
                 Relay this token to the user via a trusted out-of-band channel. \
                 It expires in 15 minutes. No email has been sent.",
            );
        }
    }

    // Always 200 -- do not reveal whether the username exists.
    Ok(StatusCode::OK)
}

// ---------------------------------------------------------------------------
// POST /api/auth/reset-password
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ResetPasswordRequest {
    pub token: String,
    pub new_password: String,
}

pub async fn reset_password(
    State(state): State<Arc<AppState>>,
    Json(body): Json<ResetPasswordRequest>,
) -> Result<impl IntoResponse, AppError> {
    validate_password(&body.new_password)?;

    let row = db::password_reset::find_token(&state.pool, &body.token)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::bad_request("Invalid or expired reset token"))?;

    if row.used_at.is_some() {
        return Err(AppError::bad_request("Reset token has already been used"));
    }
    if row.expires_at < chrono::Utc::now() {
        return Err(AppError::bad_request("Reset token has expired"));
    }

    let pw = body.new_password.clone();
    let new_hash = tokio::task::spawn_blocking(move || crate::auth::password::hash_password(&pw))
        .await
        .map_err(|_| AppError::internal("Password hashing failed"))??;

    db::users::update_password(&state.pool, row.user_id, &new_hash)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    // Mark token consumed before revoking sessions so a crash between the
    // two steps leaves the token unusable rather than sessions valid.
    db::password_reset::consume_token(&state.pool, &body.token)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    // Revoke all existing refresh tokens so any active sessions are
    // invalidated -- the password change may be the result of a compromise.
    db::tokens::revoke_all_user_tokens(&state.pool, row.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    tracing::info!(
        user_id = %row.user_id,
        "[PASSWORD RESET] Password successfully reset. All sessions invalidated.",
    );

    Ok(StatusCode::OK)
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
    use std::time::{Duration, Instant};

    let device_id = body.map(|b| b.device_id).unwrap_or(0);

    let ticket = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());

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
