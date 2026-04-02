//! User database queries.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow)]
pub struct UserRow {
    pub id: Uuid,
    #[allow(dead_code)] // Used when listing contacts
    pub username: String,
    pub password_hash: String,
    pub avatar_url: Option<String>,
    #[allow(dead_code)]
    pub display_name: Option<String>,
    #[allow(dead_code)]
    pub bio: Option<String>,
    #[allow(dead_code)]
    pub status_message: Option<String>,
}

pub async fn create_user(
    pool: &PgPool,
    username: &str,
    password_hash: &str,
) -> Result<Uuid, sqlx::Error> {
    let row: (Uuid,) =
        sqlx::query_as("INSERT INTO users (username, password_hash) VALUES ($1, $2) RETURNING id")
            .bind(username)
            .bind(password_hash)
            .fetch_one(pool)
            .await?;

    Ok(row.0)
}

pub async fn find_by_username(
    pool: &PgPool,
    username: &str,
) -> Result<Option<UserRow>, sqlx::Error> {
    sqlx::query_as::<_, UserRow>(
        "SELECT id, username, password_hash, avatar_url, display_name, bio, status_message FROM users WHERE username = $1",
    )
    .bind(username)
    .fetch_optional(pool)
    .await
}

pub async fn find_by_id(pool: &PgPool, id: Uuid) -> Result<Option<UserRow>, sqlx::Error> {
    sqlx::query_as::<_, UserRow>(
        "SELECT id, username, password_hash, avatar_url, display_name, bio, status_message FROM users WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

pub async fn set_avatar_url(
    pool: &PgPool,
    user_id: Uuid,
    avatar_url: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE users SET avatar_url = $1 WHERE id = $2")
        .bind(avatar_url)
        .bind(user_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Delete a user by ID. FK CASCADE constraints handle cleanup of related rows.
pub async fn delete_user(pool: &PgPool, user_id: Uuid) -> Result<bool, sqlx::Error> {
    let result = sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() > 0)
}

#[derive(Debug, sqlx::FromRow)]
pub struct UserProfileRow {
    pub id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub bio: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, sqlx::FromRow)]
pub struct UserPrivacyRow {
    pub read_receipts_enabled: bool,
    pub allow_unencrypted_dm: bool,
}

/// Fetch the public profile for a user by ID.
pub async fn find_public_profile(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<UserProfileRow>, sqlx::Error> {
    sqlx::query_as::<_, UserProfileRow>(
        "SELECT id, username, display_name, avatar_url, bio, created_at FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

pub async fn get_avatar_url(pool: &PgPool, user_id: Uuid) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(Option<String>,)> =
        sqlx::query_as("SELECT avatar_url FROM users WHERE id = $1")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(url,)| url))
}

pub async fn get_privacy_preferences(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<UserPrivacyRow>, sqlx::Error> {
    sqlx::query_as::<_, UserPrivacyRow>(
        "SELECT read_receipts_enabled, allow_unencrypted_dm FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

pub async fn update_privacy_preferences(
    pool: &PgPool,
    user_id: Uuid,
    read_receipts_enabled: bool,
    allow_unencrypted_dm: bool,
) -> Result<UserPrivacyRow, sqlx::Error> {
    sqlx::query_as::<_, UserPrivacyRow>(
        "UPDATE users
         SET read_receipts_enabled = $1, allow_unencrypted_dm = $2
         WHERE id = $3
         RETURNING read_receipts_enabled, allow_unencrypted_dm",
    )
    .bind(read_receipts_enabled)
    .bind(allow_unencrypted_dm)
    .bind(user_id)
    .fetch_one(pool)
    .await
}
