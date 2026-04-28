//! Refresh token database queries.
//!
//! Tokens belong to a "family" — all tokens descended from the same login
//! session share a `family_id`.  When a revoked token is presented during
//! refresh, the entire family is revoked (token theft detection per RFC 6819).
//!
//! Note: the `/api/auth/refresh` handler in `routes::auth::refresh` inlines
//! the SELECT/UPDATE/INSERT SQL inside a single transaction so the rotation
//! is atomic across concurrent requests (#520).  The helpers below are
//! retained for the non-rotation flows (initial issue, full-family revoke,
//! logout) and are intentionally not invoked by the refresh path.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow)]
pub struct RefreshTokenRow {
    pub id: Uuid,
    pub user_id: Uuid,
    #[allow(dead_code)]
    pub token_hash: String,
    pub expires_at: DateTime<Utc>,
    #[allow(dead_code)]
    pub created_at: DateTime<Utc>,
    pub revoked: bool,
    pub family_id: Option<Uuid>,
}

/// Store a new refresh token with a family_id for theft detection.
pub async fn store_refresh_token(
    pool: &PgPool,
    user_id: Uuid,
    token_hash: &str,
    expires_at: DateTime<Utc>,
) -> Result<Uuid, sqlx::Error> {
    let family_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, family_id) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(user_id)
    .bind(token_hash)
    .bind(expires_at)
    .bind(family_id)
    .execute(pool)
    .await?;
    Ok(family_id)
}

/// Store a refresh token that inherits an existing family_id (rotation).
///
/// Currently unused: the refresh path inlines this INSERT inside the
/// rotation transaction (#520).  Retained for callers that may need to
/// rotate without going through `/api/auth/refresh`.
#[allow(dead_code)]
pub async fn store_refresh_token_in_family(
    pool: &PgPool,
    user_id: Uuid,
    token_hash: &str,
    expires_at: DateTime<Utc>,
    family_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, family_id) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(user_id)
    .bind(token_hash)
    .bind(expires_at)
    .bind(family_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn find_refresh_token(
    pool: &PgPool,
    token_hash: &str,
) -> Result<Option<RefreshTokenRow>, sqlx::Error> {
    sqlx::query_as::<_, RefreshTokenRow>(
        "SELECT id, user_id, token_hash, expires_at, created_at, revoked, family_id \
         FROM refresh_tokens WHERE token_hash = $1",
    )
    .bind(token_hash)
    .fetch_optional(pool)
    .await
}

/// Unconditional single-token revoke.
///
/// Currently unused: the refresh path uses a sentinel `UPDATE ... WHERE
/// revoked = false RETURNING id` inside the rotation transaction so it can
/// detect concurrent reuse (#520).  Kept for non-rotation revocations.
#[allow(dead_code)]
pub async fn revoke_refresh_token(pool: &PgPool, token_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE refresh_tokens SET revoked = true WHERE id = $1")
        .bind(token_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Revoke ALL tokens in a family (token theft detection).
///
/// Called when a revoked token is presented during refresh — indicates the
/// token was stolen and both the attacker and legitimate user should be
/// forced to re-authenticate.
pub async fn revoke_token_family(pool: &PgPool, family_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE refresh_tokens SET revoked = true \
         WHERE family_id = $1 AND revoked = false",
    )
    .bind(family_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn revoke_all_user_tokens(pool: &PgPool, user_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE refresh_tokens SET revoked = true WHERE user_id = $1 AND revoked = false")
        .bind(user_id)
        .execute(pool)
        .await?;
    Ok(())
}
