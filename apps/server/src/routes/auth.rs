//! Authentication endpoints: register, login, refresh, logout, ws-ticket,
//! forgot-password, reset-password.

use axum::Json;
use axum::extract::State;
use axum::extract::rejection::JsonRejection;
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

use crate::auth::middleware::AuthUser;
use crate::auth::{jwt, password};
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};

use super::AuthExtract;

// ---------------------------------------------------------------------------
// Refresh token cookie helpers
// ---------------------------------------------------------------------------
// SameSite=None is required across the web↔API origin split (#1063); CSRF is
// bounded by the credentialed-CORS allow-list (see `routes/mod.rs`).

const REFRESH_COOKIE_NAME: &str = "echo_refresh";
const REFRESH_COOKIE_MAX_AGE_SECS: i64 = 7 * 24 * 60 * 60;

fn build_refresh_cookie(value: String) -> Cookie<'static> {
    Cookie::build((REFRESH_COOKIE_NAME, value))
        .http_only(true)
        .secure(true)
        .same_site(SameSite::None)
        .path("/api/auth")
        .max_age(time::Duration::seconds(REFRESH_COOKIE_MAX_AGE_SECS))
        .build()
}

/// TD-43: enforce an Origin-header check on the two cookie-credentialed
/// endpoints (`/refresh` and `/logout`) so a malicious page served by an
/// origin **not** in `CORS_ORIGINS` cannot fire a credentialed
/// `fetch(..., {credentials: 'include'})` to forcibly rotate or kill the
/// user's session.
///
/// Browsers send `Origin:` on all credentialed cross-origin fetches; same-
/// origin requests typically send it too on POST. We accept the request
/// only when `Origin` is either absent (non-browser clients like our
/// mobile/desktop apps don't set it) or matches an entry in the parsed
/// allow-list.
fn allowed_origins() -> &'static [String] {
    static LIST: OnceLock<Vec<String>> = OnceLock::new();
    LIST.get_or_init(|| {
        let raw = std::env::var("CORS_ORIGINS").unwrap_or_else(|_| {
            "https://echo-messenger.us,https://web.echo-messenger.us,http://localhost:8081".into()
        });
        if raw.trim() == "*" {
            // Wildcard CORS disables credentials → no Origin check applies.
            return Vec::new();
        }
        raw.split(',')
            .map(|s| s.trim().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
            .collect()
    })
}

/// Returns Err(AppError::forbidden) when the request carries an `Origin`
/// header outside the allow-list. Absent header is allowed (mobile/desktop).
fn validate_origin_for_credentialed(headers: &HeaderMap) -> Result<(), AppError> {
    let Some(origin_val) = headers.get(axum::http::header::ORIGIN) else {
        return Ok(());
    };
    let Ok(origin) = origin_val.to_str() else {
        return Err(AppError::forbidden("Invalid Origin header"));
    };
    let normalised = origin.trim_end_matches('/');
    let allow = allowed_origins();
    if allow.is_empty() || allow.iter().any(|o| o == normalised) {
        return Ok(());
    }
    tracing::warn!(
        origin = %origin,
        "rejected credentialed request from non-allowed Origin"
    );
    Err(AppError::forbidden("Origin not in credentialed allow-list"))
}

fn clear_refresh_cookie() -> Cookie<'static> {
    Cookie::build((REFRESH_COOKIE_NAME, ""))
        .http_only(true)
        .secure(true)
        .same_site(SameSite::None)
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
    /// Operator flag: lets the client gate the admin dashboard tile in
    /// settings without an extra round-trip. Fresh server bootstrap (no
    /// admin yet) auto-promotes the first registered account.
    pub is_admin: bool,
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
    /// Echoed from the user row so a client that signed in before the
    /// operator was promoted picks up the new flag without re-logging in.
    pub is_admin: bool,
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
    State(state): State<AuthExtract>,
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
    let created = db::users::create_user(&state.pool, &body.username, &password_hash).await?;
    let access_token = jwt::create_token(created.id, &state.jwt_secret)?;
    let (refresh_token, _family_id) = issue_refresh_token(&state.pool, created.id).await?;

    // Web clients consume the cookie; mobile/desktop still read the JSON body.
    let jar = jar.add(build_refresh_cookie(refresh_token.clone()));

    let response = AuthResponse {
        user_id: created.id.to_string(),
        access_token,
        refresh_token,
        avatar_url: None,
        is_admin: created.is_admin,
    };

    Ok((StatusCode::CREATED, jar, Json(response)))
}

// ---------------------------------------------------------------------------
// POST /api/auth/login
// ---------------------------------------------------------------------------

pub async fn login(
    State(state): State<AuthExtract>,
    jar: CookieJar,
    Json(body): Json<AuthRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Dummy hash used when the user is missing so login latency does not leak
    // username existence; output length matches Argon2::default().
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
            state.failed_logins.inc();
            return Err(AppError::with_code(
                ErrorCode::InvalidCredentials,
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
        is_admin: user.is_admin,
    };

    Ok((jar, Json(response)))
}

// ---------------------------------------------------------------------------
// POST /api/auth/refresh
// ---------------------------------------------------------------------------

/// Atomically validate and rotate a refresh token.
///
/// The whole flow — SELECT (with row lock), revoke-old, INSERT-new — runs in a
/// single transaction so two concurrent requests presenting the same refresh
/// token cannot both succeed.  The first to reach the sentinel UPDATE wins;
/// the second gets `None` from the conditional UPDATE, treats it as
/// concurrent reuse, family-revokes, and returns 401.  This prevents the race
/// where both callers observed `revoked = false` in the old non-transactional
/// code path.
pub async fn refresh(
    State(state): State<AuthExtract>,
    headers: HeaderMap,
    jar: CookieJar,
    // `Result<Json<_>, _>` not `Option<Json<_>>`: an empty body would otherwise
    // reject before we read the cookie and log the web client out on refresh.
    body: Result<Json<RefreshRequest>, JsonRejection>,
) -> Result<impl IntoResponse, AppError> {
    // TD-43: forbid credentialed cookie use from origins outside the
    // allow-list. Absent Origin (mobile/desktop) passes through.
    validate_origin_for_credentialed(&headers)?;

    // Cookie wins over body so a malicious JSON body cannot override the
    // web client's HttpOnly cookie; mobile/desktop continue to send via body.
    let cookie_token = jar
        .get(REFRESH_COOKIE_NAME)
        .map(|c| c.value().to_string())
        .filter(|s| !s.is_empty());
    let body_token = body
        .ok()
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

    // Sentinel revoke: only one tx can flip `revoked` false→true; `None`
    // means a concurrent reuse — family-revoke.
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

    // Re-read is_admin so promotion/demotion propagates on the next refresh.
    let (is_admin,): (bool,) = sqlx::query_as("SELECT is_admin FROM users WHERE id = $1")
        .bind(row.user_id)
        .fetch_one(&state.pool)
        .await
        .db_ctx("refresh/lookup_is_admin")?;

    let jar = jar.add(build_refresh_cookie(new_raw_token.clone()));

    Ok((
        jar,
        Json(RefreshResponse {
            access_token,
            refresh_token: new_raw_token,
            is_admin,
        }),
    ))
}

// ---------------------------------------------------------------------------
// POST /api/auth/logout
// ---------------------------------------------------------------------------

pub async fn logout(
    State(state): State<AuthExtract>,
    headers: HeaderMap,
    jar: CookieJar,
    auth_user: AuthUser,
) -> Result<impl IntoResponse, AppError> {
    // TD-43: cookie-credentialed endpoint — bounce non-allowed Origins.
    validate_origin_for_credentialed(&headers)?;

    db::tokens::revoke_all_user_tokens(&state.pool, auth_user.user_id).await?;
    // CR-4: invalidate the access token immediately so it cannot be used
    // for the remainder of its 15-minute TTL.
    state.token_invalidator.invalidate(auth_user.user_id);
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
/// (admin-mediated only, no SMTP infra yet -- #476). The operator must
/// deliver the token to the user out-of-band (e.g. via direct message or
/// support ticket). A follow-up issue should add SMTP support for
/// production deployments.
///
/// # Security note
/// The raw token is intentionally included in the log so the operator can
/// copy-paste it without a DB query. This means log access during the
/// 15-minute window is sufficient to take over the account. Restrict log
/// access accordingly, or add SMTP and remove the token from this log line.
pub async fn forgot_password(
    State(state): State<AuthExtract>,
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
            // SECURITY: never log the token — log access would equal account
            // takeover. Operators read it from `password_reset_tokens` directly.
            tracing::info!(
                user_id = %user.id,
                expires = %expires_at,
                "[manual reset] Password reset requested. \
                 Read the token row from `password_reset_tokens` and \
                 deliver it to the user out-of-band.",
            );
        }
    }

    // Always 200 — do not reveal whether the username exists. TD-73: JSON body
    // (not empty) keeps fetch wrappers happy with the Content-Type expectation.
    Ok((StatusCode::OK, Json(serde_json::json!({"ok": true}))))
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
    State(state): State<AuthExtract>,
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

    // All three writes must succeed or fail together: a partial apply lets
    // the same reset token be replayed once the next write recovers.
    let mut tx = state
        .pool
        .begin()
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    db::users::update_password(&mut *tx, row.user_id, &new_hash)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    db::password_reset::consume_token(&mut *tx, &body.token)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    // Revoke all existing refresh tokens so any active sessions are
    // invalidated -- the password change may be the result of a compromise.
    db::tokens::revoke_all_user_tokens(&mut *tx, row.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    tx.commit()
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    // CR-4: invalidate outstanding access tokens too (refresh tokens were
    // revoked inside the tx above).
    state.token_invalidator.invalidate(row.user_id);

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
    State(state): State<AuthExtract>,
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
