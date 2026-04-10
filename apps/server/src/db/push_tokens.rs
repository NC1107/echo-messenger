//! Push notification token storage.

use sqlx::PgPool;
use uuid::Uuid;

/// Register or update a push token for a user.
/// Uses ON CONFLICT to upsert -- if the same token already exists for this
/// user, just update the timestamp.
pub async fn upsert_token(
    pool: &PgPool,
    user_id: Uuid,
    token: &str,
    platform: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO push_tokens (user_id, token, platform)
         VALUES ($1, $2, $3)
         ON CONFLICT (user_id, token) DO UPDATE SET updated_at = NOW(), platform = $3",
    )
    .bind(user_id)
    .bind(token)
    .bind(platform)
    .execute(pool)
    .await?;
    Ok(())
}

/// Remove a specific push token (e.g. on logout).
pub async fn remove_token(pool: &PgPool, user_id: Uuid, token: &str) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM push_tokens WHERE user_id = $1 AND token = $2")
        .bind(user_id)
        .bind(token)
        .execute(pool)
        .await?;
    Ok(())
}

/// Remove all push tokens for a user (e.g. on account deletion).
pub async fn remove_all_tokens(pool: &PgPool, user_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM push_tokens WHERE user_id = $1")
        .bind(user_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Get all push tokens for a user.
pub async fn get_tokens(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Vec<(String, String)>, sqlx::Error> {
    let rows: Vec<(String, String)> =
        sqlx::query_as("SELECT token, platform FROM push_tokens WHERE user_id = $1")
            .bind(user_id)
            .fetch_all(pool)
            .await?;
    Ok(rows)
}

/// Get push tokens for multiple users at once (batch lookup for fan-out).
pub async fn get_tokens_for_users(
    pool: &PgPool,
    user_ids: &[Uuid],
) -> Result<Vec<(Uuid, String, String)>, sqlx::Error> {
    let rows: Vec<(Uuid, String, String)> =
        sqlx::query_as("SELECT user_id, token, platform FROM push_tokens WHERE user_id = ANY($1)")
            .bind(user_ids)
            .fetch_all(pool)
            .await?;
    Ok(rows)
}
