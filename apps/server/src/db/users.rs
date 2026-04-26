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
    #[allow(dead_code)]
    pub status_text: Option<String>,
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
        "SELECT id, username, password_hash, avatar_url, display_name, bio, status_message, status_text FROM users WHERE username = $1",
    )
    .bind(username)
    .fetch_optional(pool)
    .await
}

pub async fn find_by_id(pool: &PgPool, id: Uuid) -> Result<Option<UserRow>, sqlx::Error> {
    sqlx::query_as::<_, UserRow>(
        "SELECT id, username, password_hash, avatar_url, display_name, bio, status_message, status_text FROM users WHERE id = $1",
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
    pub email: Option<String>,
    pub phone: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, sqlx::FromRow)]
pub struct UserPrivacyRow {
    pub read_receipts_enabled: bool,
    pub allow_unencrypted_dm: bool,
    pub email_visible: bool,
    pub phone_visible: bool,
    pub email_discoverable: bool,
    pub phone_discoverable: bool,
    pub searchable: bool,
}

#[derive(Debug, sqlx::FromRow)]
pub struct UsernameInviteResolutionRow {
    pub id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub bio: Option<String>,
    pub status_message: Option<String>,
    pub relationship: String,
    pub searchable: bool,
}

/// Search users by username, email, or phone prefix (case-insensitive).
/// Returns up to 10 results. Excludes the calling user from results.
/// Email matches only when the user has `email_discoverable` enabled;
/// phone matches only when `phone_discoverable` is enabled.
pub async fn search_users(
    pool: &PgPool,
    query: &str,
    exclude_user_id: Uuid,
) -> Result<Vec<UserProfileRow>, sqlx::Error> {
    let escaped = query
        .to_lowercase()
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    let pattern = format!("{escaped}%");
    sqlx::query_as::<_, UserProfileRow>(
        "SELECT id, username, display_name, avatar_url, bio, status_message, \
         timezone, pronouns, website, \
         CASE WHEN email_visible THEN email ELSE NULL END AS email, \
         CASE WHEN phone_visible THEN phone ELSE NULL END AS phone, \
         created_at \
         FROM users \
         WHERE id != $2 AND searchable = true AND ( \
           LOWER(username) LIKE $1 ESCAPE '\\' \
           OR (email_discoverable AND LOWER(email) LIKE $1 ESCAPE '\\') \
           OR (phone_discoverable AND phone LIKE $1 ESCAPE '\\') \
         ) \
         ORDER BY username \
         LIMIT 10",
    )
    .bind(&pattern)
    .bind(exclude_user_id)
    .fetch_all(pool)
    .await
}

/// Resolve a username for DM invites, including relationship state.
///
/// Relationship values:
/// - "contact": accepted contact relation exists
/// - "pending": pending request exists in either direction
/// - "none": no relationship
/// - "blocked": one user blocked the other
pub async fn resolve_username_invite(
    pool: &PgPool,
    viewer_user_id: Uuid,
    username: &str,
) -> Result<Option<UsernameInviteResolutionRow>, sqlx::Error> {
    sqlx::query_as::<_, UsernameInviteResolutionRow>(
        "SELECT
            u.id,
            u.username,
            u.display_name,
            u.avatar_url,
            u.bio,
            u.status_message,
            CASE
                WHEN rel.is_blocked THEN 'blocked'
                WHEN rel.has_contact THEN 'contact'
                WHEN rel.has_pending THEN 'pending'
                ELSE 'none'
            END AS relationship,
            u.searchable
         FROM users u
         LEFT JOIN LATERAL (
            SELECT
                EXISTS(
                    SELECT 1
                    FROM blocked_users b
                    WHERE (b.blocker_id = $1 AND b.blocked_id = u.id)
                       OR (b.blocker_id = u.id AND b.blocked_id = $1)
                ) AS is_blocked,
                EXISTS(
                    SELECT 1
                    FROM contacts c
                    WHERE c.status = 'accepted'
                      AND ((c.requester_id = $1 AND c.target_id = u.id)
                        OR (c.requester_id = u.id AND c.target_id = $1))
                ) AS has_contact,
                EXISTS(
                    SELECT 1
                    FROM contacts c
                    WHERE c.status = 'pending'
                      AND ((c.requester_id = $1 AND c.target_id = u.id)
                        OR (c.requester_id = u.id AND c.target_id = $1))
                ) AS has_pending
         ) rel ON true
         WHERE LOWER(u.username) = LOWER($2)
           AND u.id != $1",
    )
    .bind(viewer_user_id)
    .bind(username)
    .fetch_optional(pool)
    .await
}

/// Fetch the public profile for a user by ID.
pub async fn find_public_profile(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<UserProfileRow>, sqlx::Error> {
    sqlx::query_as::<_, UserProfileRow>(
        "SELECT id, username, display_name, avatar_url, bio, status_message, \
         timezone, pronouns, website, \
         CASE WHEN email_visible THEN email ELSE NULL END AS email, \
         CASE WHEN phone_visible THEN phone ELSE NULL END AS phone, \
         created_at \
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
    pub email: Option<&'a str>,
    pub phone: Option<&'a str>,
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
         website = CASE WHEN $7 IS NULL THEN website ELSE NULLIF($7, '') END, \
         email = CASE WHEN $8 IS NULL THEN email ELSE NULLIF($8, '') END, \
         phone = CASE WHEN $9 IS NULL THEN phone ELSE NULLIF($9, '') END \
         WHERE id = $1 \
         RETURNING id, username, display_name, avatar_url, bio, status_message, \
                  timezone, pronouns, website, email, phone, created_at",
    )
    .bind(user_id)
    .bind(fields.display_name)
    .bind(fields.bio)
    .bind(fields.status_message)
    .bind(fields.timezone)
    .bind(fields.pronouns)
    .bind(fields.website)
    .bind(fields.email)
    .bind(fields.phone)
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
        "SELECT read_receipts_enabled, allow_unencrypted_dm, \
         email_visible, phone_visible, email_discoverable, phone_discoverable, \
         searchable \
         FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

/// All privacy preference fields for an update.
pub struct PrivacyUpdate {
    pub read_receipts_enabled: bool,
    pub allow_unencrypted_dm: bool,
    pub email_visible: bool,
    pub phone_visible: bool,
    pub email_discoverable: bool,
    pub phone_discoverable: bool,
    pub searchable: bool,
}

/// Update the presence_status for a user. Returns the stored value.
pub async fn update_presence_status(
    pool: &PgPool,
    user_id: Uuid,
    status: &str,
) -> Result<String, sqlx::Error> {
    let row: (String,) = sqlx::query_as(
        "UPDATE users SET presence_status = $1 WHERE id = $2 RETURNING presence_status",
    )
    .bind(status)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

/// Fetch the presence_status for a user.
pub async fn get_presence_status(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(String,)> = sqlx::query_as("SELECT presence_status FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(s,)| s))
}

pub async fn update_privacy_preferences(
    pool: &PgPool,
    user_id: Uuid,
    prefs: &PrivacyUpdate,
) -> Result<UserPrivacyRow, sqlx::Error> {
    sqlx::query_as::<_, UserPrivacyRow>(
        "UPDATE users \
         SET read_receipts_enabled = $1, allow_unencrypted_dm = $2, \
             email_visible = $3, phone_visible = $4, \
             email_discoverable = $5, phone_discoverable = $6, \
             searchable = $7 \
         WHERE id = $8 \
         RETURNING read_receipts_enabled, allow_unencrypted_dm, \
                  email_visible, phone_visible, email_discoverable, phone_discoverable, \
                  searchable",
    )
    .bind(prefs.read_receipts_enabled)
    .bind(prefs.allow_unencrypted_dm)
    .bind(prefs.email_visible)
    .bind(prefs.phone_visible)
    .bind(prefs.email_discoverable)
    .bind(prefs.phone_discoverable)
    .bind(prefs.searchable)
    .bind(user_id)
    .fetch_one(pool)
    .await
}

/// Set the user's custom status text (max 64 chars, NULL to clear).
pub async fn update_status_text(
    pool: &PgPool,
    user_id: Uuid,
    status_text: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE users SET status_text = $1 WHERE id = $2")
        .bind(status_text)
        .bind(user_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Fetch the status_text for a user.
pub async fn get_status_text(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(Option<String>,)> =
        sqlx::query_as("SELECT status_text FROM users WHERE id = $1")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(t,)| t))
}

/// Add or remove a conversation pin for a user.
pub async fn pin_conversation(
    pool: &PgPool,
    user_id: Uuid,
    conversation_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO pinned_conversations (user_id, conversation_id) \
         VALUES ($1, $2) ON CONFLICT DO NOTHING",
    )
    .bind(user_id)
    .bind(conversation_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn unpin_conversation(
    pool: &PgPool,
    user_id: Uuid,
    conversation_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "DELETE FROM pinned_conversations WHERE user_id = $1 AND conversation_id = $2",
    )
    .bind(user_id)
    .bind(conversation_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn get_pinned_conversations(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Vec<Uuid>, sqlx::Error> {
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT conversation_id FROM pinned_conversations WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
}
