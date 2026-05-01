//! Password-reset token database queries (#476).
//!
//! Tokens are single-use and expire after 15 minutes. No email
//! infrastructure exists yet; tokens are logged to stdout by the route
//! handler for admin-mediated relay (Option A).

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

/// Store a new password-reset token for `user_id`, expiring at `expires_at`.
pub async fn create_token(
    pool: &PgPool,
    token: &str,
    user_id: Uuid,
    expires_at: DateTime<Utc>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO password_reset_tokens (token, user_id, expires_at) \
         VALUES ($1, $2, $3)",
    )
    .bind(token)
    .bind(user_id)
    .bind(expires_at)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(Debug, sqlx::FromRow)]
pub struct ResetTokenRow {
    pub user_id: Uuid,
    pub expires_at: DateTime<Utc>,
    pub used_at: Option<DateTime<Utc>>,
}

/// Look up a reset token. Returns `None` when the token does not exist.
pub async fn find_token(pool: &PgPool, token: &str) -> Result<Option<ResetTokenRow>, sqlx::Error> {
    sqlx::query_as::<_, ResetTokenRow>(
        "SELECT user_id, expires_at, used_at \
         FROM password_reset_tokens WHERE token = $1",
    )
    .bind(token)
    .fetch_optional(pool)
    .await
}

/// Mark the token as used. Called immediately after a successful password reset.
pub async fn consume_token(pool: &PgPool, token: &str) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE password_reset_tokens SET used_at = NOW() WHERE token = $1")
        .bind(token)
        .execute(pool)
        .await?;
    Ok(())
}
