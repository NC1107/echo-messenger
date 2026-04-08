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
    pub status_message: Option<String>,
    pub timezone: Option<String>,
    pub pronouns: Option<String>,
    pub website: Option<String>,
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
        "SELECT id, username, display_name, avatar_url, bio, status_message, \
         timezone, pronouns, website, created_at \
         FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

/// Fields that can be updated on a user's profile.
pub struct ProfileUpdate<'a> {
    pub display_name: Option<&'a str>,
    pub bio: Option<&'a str>,
    pub status_message: Option<&'a str>,
    pub timezone: Option<&'a str>,
    pub pronouns: Option<&'a str>,
    pub website: Option<&'a str>,
}

/// Update profile fields for a user. Only non-null fields are updated.
pub async fn update_profile(
    pool: &PgPool,
    user_id: Uuid,
    fields: &ProfileUpdate<'_>,
) -> Result<UserProfileRow, sqlx::Error> {
    // NULL = field not in request (keep existing value).
    // Empty string = user cleared the field (set to NULL in DB).
    // Non-empty string = user set a value (store it).
    sqlx::query_as::<_, UserProfileRow>(
        "UPDATE users SET \
         display_name = CASE WHEN $2 IS NULL THEN display_name ELSE NULLIF($2, '') END, \
         bio = CASE WHEN $3 IS NULL THEN bio ELSE NULLIF($3, '') END, \
         status_message = CASE WHEN $4 IS NULL THEN status_message ELSE NULLIF($4, '') END, \
         timezone = CASE WHEN $5 IS NULL THEN timezone ELSE NULLIF($5, '') END, \
         pronouns = CASE WHEN $6 IS NULL THEN pronouns ELSE NULLIF($6, '') END, \
         website = CASE WHEN $7 IS NULL THEN website ELSE NULLIF($7, '') END \
         WHERE id = $1 \
         RETURNING id, username, display_name, avatar_url, bio, status_message, \
                  timezone, pronouns, website, created_at",
    )
    .bind(user_id)
    .bind(fields.display_name)
    .bind(fields.bio)
    .bind(fields.status_message)
    .bind(fields.timezone)
    .bind(fields.pronouns)
    .bind(fields.website)
    .fetch_one(pool)
    .await
}

/// Update a user's password hash.
pub async fn update_password(
    pool: &PgPool,
    user_id: Uuid,
    password_hash: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE users SET password_hash = $1 WHERE id = $2")
        .bind(password_hash)
        .bind(user_id)
        .execute(pool)
        .await?;
    Ok(())
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
