//! Group conversation database queries.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, Serialize)]
pub struct GroupInfo {
    pub id: Uuid,
    pub title: Option<String>,
    pub kind: String,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, sqlx::FromRow, Serialize)]
pub struct GroupMember {
    pub user_id: Uuid,
    pub username: String,
    pub joined_at: DateTime<Utc>,
    pub role: String,
    pub avatar_url: Option<String>,
}

/// Create a group conversation with visibility setting and add the creator plus initial members.
pub async fn create_group_with_visibility(
    pool: &PgPool,
    creator_id: Uuid,
    name: &str,
    member_ids: &[Uuid],
    is_public: bool,
    description: Option<&str>,
) -> Result<GroupInfo, sqlx::Error> {
    let mut tx = pool.begin().await?;

    let group: GroupInfo = sqlx::query_as(
        "INSERT INTO conversations (kind, title, is_public, description) \
         VALUES ('group', $1, $2, $3) \
         RETURNING id, title, kind, description, icon_url, created_at",
    )
    .bind(name)
    .bind(is_public)
    .bind(description)
    .fetch_one(&mut *tx)
    .await?;

    // Add creator as owner
    sqlx::query(
        "INSERT INTO conversation_members (conversation_id, user_id, role) VALUES ($1, $2, 'owner')",
    )
    .bind(group.id)
    .bind(creator_id)
    .execute(&mut *tx)
    .await?;

    // Add other members
    for member_id in member_ids {
        if *member_id == creator_id {
            continue;
        }
        sqlx::query(
            "INSERT INTO conversation_members (conversation_id, user_id, role) VALUES ($1, $2, 'member') \
             ON CONFLICT DO NOTHING",
        )
        .bind(group.id)
        .bind(member_id)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(group)
}

#[derive(Debug, sqlx::FromRow, Serialize)]
pub struct PublicGroupRow {
    pub id: Uuid,
    pub title: Option<String>,
    pub member_count: i64,
    pub created_at: DateTime<Utc>,
    pub is_member: bool,
}

/// List public groups, optionally filtered by title search, with pagination.
pub async fn list_public_groups(
    pool: &PgPool,
    user_id: Uuid,
    search: Option<&str>,
    limit: i64,
    offset: i64,
) -> Result<Vec<PublicGroupRow>, sqlx::Error> {
    match search {
        Some(term) => {
            let pattern = format!("%{}%", term);
            sqlx::query_as::<_, PublicGroupRow>(
                "SELECT c.id, c.title, \
                 COUNT(cm.user_id) AS member_count, c.created_at, \
                 EXISTS(SELECT 1 FROM conversation_members cm2 \
                        WHERE cm2.conversation_id = c.id \
                        AND cm2.user_id = $2 AND cm2.is_removed = false) AS is_member \
                 FROM conversations c \
                 LEFT JOIN conversation_members cm \
                   ON cm.conversation_id = c.id AND cm.is_removed = false \
                 WHERE c.is_public = true AND c.kind = 'group' \
                   AND c.title ILIKE $1 \
                 GROUP BY c.id \
                 ORDER BY c.created_at DESC \
                 LIMIT $3 OFFSET $4",
            )
            .bind(pattern)
            .bind(user_id)
            .bind(limit)
            .bind(offset)
            .fetch_all(pool)
            .await
        }
        None => {
            sqlx::query_as::<_, PublicGroupRow>(
                "SELECT c.id, c.title, \
                 COUNT(cm.user_id) AS member_count, c.created_at, \
                 EXISTS(SELECT 1 FROM conversation_members cm2 \
                        WHERE cm2.conversation_id = c.id \
                        AND cm2.user_id = $1 AND cm2.is_removed = false) AS is_member \
                 FROM conversations c \
                 LEFT JOIN conversation_members cm \
                   ON cm.conversation_id = c.id AND cm.is_removed = false \
                 WHERE c.is_public = true AND c.kind = 'group' \
                 GROUP BY c.id \
                 ORDER BY c.created_at DESC \
                 LIMIT $2 OFFSET $3",
            )
            .bind(user_id)
            .bind(limit)
            .bind(offset)
            .fetch_all(pool)
            .await
        }
    }
}

/// Join a public group. Returns an error if the group is not public.
///
/// Uses a single atomic INSERT ... SELECT to avoid a TOCTOU race between
/// checking `is_public` and inserting the membership row.
pub async fn join_public_group(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
        "INSERT INTO conversation_members (conversation_id, user_id, role) \
         SELECT $1, $2, 'member' \
         FROM conversations \
         WHERE id = $1 AND kind = 'group' AND is_public = true \
         ON CONFLICT (conversation_id, user_id) DO UPDATE \
           SET is_removed = false, removed_at = NULL, role = 'member'",
    )
    .bind(group_id)
    .bind(user_id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() > 0)
}

/// Get group info by conversation ID.
pub async fn get_group(pool: &PgPool, group_id: Uuid) -> Result<Option<GroupInfo>, sqlx::Error> {
    sqlx::query_as::<_, GroupInfo>(
        "SELECT id, title, kind, description, icon_url, created_at \
         FROM conversations WHERE id = $1 AND kind = 'group'",
    )
    .bind(group_id)
    .fetch_optional(pool)
    .await
}

/// Get all members of a group.
pub async fn get_group_members(
    pool: &PgPool,
    group_id: Uuid,
) -> Result<Vec<GroupMember>, sqlx::Error> {
    sqlx::query_as::<_, GroupMember>(
        "SELECT cm.user_id, u.username, cm.joined_at, cm.role, u.avatar_url \
         FROM conversation_members cm \
         JOIN users u ON u.id = cm.user_id \
         WHERE cm.conversation_id = $1 AND cm.is_removed = false \
         ORDER BY cm.joined_at",
    )
    .bind(group_id)
    .fetch_all(pool)
    .await
}

/// Check if a user is a member of a conversation.
pub async fn is_member(
    pool: &PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS(SELECT 1 FROM conversation_members \
         WHERE conversation_id = $1 AND user_id = $2 AND is_removed = false)",
    )
    .bind(conversation_id)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

/// Get a member's role in a conversation. Returns None if not a member.
pub async fn get_member_role(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT role FROM conversation_members \
         WHERE conversation_id = $1 AND user_id = $2 AND is_removed = false",
    )
    .bind(group_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(role,)| role))
}

/// Add a member to a group.
///
/// Returns `true` when a row was inserted or a soft-removed membership was
/// reactivated, and `false` when the user is already an active member.
pub async fn add_member(pool: &PgPool, group_id: Uuid, user_id: Uuid) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
                "INSERT INTO conversation_members (conversation_id, user_id, role) VALUES ($1, $2, 'member') \
                 ON CONFLICT (conversation_id, user_id) DO UPDATE \
                     SET is_removed = false, removed_at = NULL, role = 'member' \
                 WHERE conversation_members.is_removed = true",
        )
        .bind(group_id)
        .bind(user_id)
        .execute(pool)
        .await?;

    Ok(result.rows_affected() > 0)
}

/// Remove a member from a group.
pub async fn remove_member(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
        "UPDATE conversation_members \
         SET is_removed = true, removed_at = NOW() \
         WHERE conversation_id = $1 AND user_id = $2 AND is_removed = false",
    )
    .bind(group_id)
    .bind(user_id)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() > 0)
}

/// Get all member user IDs for a conversation (works for both DMs and groups).
pub async fn get_conversation_member_ids(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Vec<Uuid>, sqlx::Error> {
    let rows: Vec<(Uuid,)> =
        sqlx::query_as("SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND is_removed = false")
            .bind(conversation_id)
            .fetch_all(pool)
            .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
}

/// Get the kind of a conversation.
pub async fn get_conversation_kind(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(String,)> = sqlx::query_as("SELECT kind FROM conversations WHERE id = $1")
        .bind(conversation_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(kind,)| kind))
}

/// Check if a user already owns a public group with the given title.
pub async fn user_has_public_group_named(
    pool: &PgPool,
    user_id: Uuid,
    title: &str,
) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS(\
            SELECT 1 FROM conversations c \
            JOIN conversation_members cm ON cm.conversation_id = c.id \
            WHERE cm.user_id = $1 AND cm.role = 'owner' AND cm.is_removed = false \
              AND c.title = $2 AND c.is_public = true\
        )",
    )
    .bind(user_id)
    .bind(title)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

/// Delete a group conversation. Only the owner can delete it.
/// Deleting the conversation cascades to members and messages via FK constraints.
///
/// Uses a single atomic DELETE with an EXISTS subquery to avoid a TOCTOU race
/// between the ownership check and the delete.
pub async fn delete_group(
    pool: &PgPool,
    group_id: Uuid,
    owner_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
        "DELETE FROM conversations WHERE id = $1 AND EXISTS(\
             SELECT 1 FROM conversation_members \
             WHERE conversation_id = $1 AND user_id = $2 AND role = 'owner' \
               AND is_removed = false\
         )",
    )
    .bind(group_id)
    .bind(owner_id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() > 0)
}

/// Check if a group is public.
pub async fn is_public(pool: &PgPool, group_id: Uuid) -> Result<bool, sqlx::Error> {
    let row: Option<(bool,)> = sqlx::query_as("SELECT is_public FROM conversations WHERE id = $1")
        .bind(group_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(p,)| p).unwrap_or(false))
}

/// Preview row returned by [`get_group_preview`].
#[derive(Debug, sqlx::FromRow, Serialize)]
pub struct GroupPreviewRow {
    pub id: Uuid,
    pub title: Option<String>,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    pub member_count: i64,
    pub is_public: bool,
    pub is_member: bool,
}

/// Get a lightweight preview of a group.
///
/// Returns data for **public** groups even if the caller is not a member.
/// For private groups the caller must already be a member; otherwise `None`
/// is returned.
pub async fn get_group_preview(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<Option<GroupPreviewRow>, sqlx::Error> {
    sqlx::query_as::<_, GroupPreviewRow>(
        "SELECT c.id, c.title, c.description, c.icon_url, c.is_public, \
         COUNT(cm.user_id) AS member_count, \
         EXISTS(SELECT 1 FROM conversation_members cm2 \
                WHERE cm2.conversation_id = c.id AND cm2.user_id = $2 \
                  AND cm2.is_removed = false) AS is_member \
         FROM conversations c \
         LEFT JOIN conversation_members cm ON cm.conversation_id = c.id \
           AND cm.is_removed = false \
         WHERE c.id = $1 AND c.kind = 'group' \
           AND (c.is_public = true OR EXISTS( \
                SELECT 1 FROM conversation_members cm3 \
                WHERE cm3.conversation_id = c.id AND cm3.user_id = $2 \
                  AND cm3.is_removed = false)) \
         GROUP BY c.id",
    )
    .bind(group_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

/// Get up to `limit` member avatars/usernames for a group (for preview strips).
pub async fn get_group_member_previews(
    pool: &PgPool,
    group_id: Uuid,
    limit: i64,
) -> Result<Vec<GroupMember>, sqlx::Error> {
    sqlx::query_as::<_, GroupMember>(
        "SELECT cm.user_id, u.username, cm.joined_at, cm.role, u.avatar_url \
         FROM conversation_members cm \
         JOIN users u ON u.id = cm.user_id \
         WHERE cm.conversation_id = $1 AND cm.is_removed = false \
         ORDER BY cm.joined_at \
         LIMIT $2",
    )
    .bind(group_id)
    .bind(limit)
    .fetch_all(pool)
    .await
}

pub async fn update_group_title(
    pool: &PgPool,
    group_id: Uuid,
    title: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE conversations SET title = $1 WHERE id = $2")
        .bind(title)
        .bind(group_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn update_group_description(
    pool: &PgPool,
    group_id: Uuid,
    description: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE conversations SET description = $1 WHERE id = $2")
        .bind(description)
        .bind(group_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Ban a member: remove from group + add to banned_members table.
pub async fn ban_member(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
    banned_by: Uuid,
) -> Result<bool, sqlx::Error> {
    let mut tx = pool.begin().await?;

    // Remove from conversation_members (soft-delete)
    sqlx::query(
        "UPDATE conversation_members SET is_removed = true, removed_at = NOW() \
         WHERE conversation_id = $1 AND user_id = $2 AND is_removed = false",
    )
    .bind(group_id)
    .bind(user_id)
    .execute(&mut *tx)
    .await?;

    // Insert into banned_members (upsert to handle re-ban)
    let result = sqlx::query(
        "INSERT INTO banned_members (conversation_id, user_id, banned_by) \
         VALUES ($1, $2, $3) \
         ON CONFLICT (conversation_id, user_id) DO UPDATE SET banned_at = now(), banned_by = $3",
    )
    .bind(group_id)
    .bind(user_id)
    .bind(banned_by)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(result.rows_affected() > 0)
}

/// Check if a user is banned from a group.
pub async fn is_banned(pool: &PgPool, group_id: Uuid, user_id: Uuid) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS(SELECT 1 FROM banned_members \
         WHERE conversation_id = $1 AND user_id = $2)",
    )
    .bind(group_id)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

/// Force-delete a conversation (used for empty groups with no members).
pub async fn force_delete_conversation(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM conversations WHERE id = $1")
        .bind(conversation_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Update the icon_url (group avatar) for a conversation.
pub async fn update_group_icon_url(
    pool: &PgPool,
    group_id: Uuid,
    icon_url: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE conversations SET icon_url = $1 WHERE id = $2")
        .bind(icon_url)
        .bind(group_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Get the icon_url for a conversation. Returns None if unset.
pub async fn get_group_icon_url(
    pool: &PgPool,
    group_id: Uuid,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(Option<String>,)> =
        sqlx::query_as("SELECT icon_url FROM conversations WHERE id = $1")
            .bind(group_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(url,)| url))
}

/// Unban a user from a group.
pub async fn unban_member(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result =
        sqlx::query("DELETE FROM banned_members WHERE conversation_id = $1 AND user_id = $2")
            .bind(group_id)
            .bind(user_id)
            .execute(pool)
            .await?;
    Ok(result.rows_affected() > 0)
}

// ---------------------------------------------------------------------------
// Group key rotation (#656)
// ---------------------------------------------------------------------------

/// Returns true when the conversation row has `is_encrypted = true`.
pub async fn is_encrypted(pool: &PgPool, conversation_id: Uuid) -> Result<bool, sqlx::Error> {
    let row: Option<(bool,)> =
        sqlx::query_as("SELECT is_encrypted FROM conversations WHERE id = $1")
            .bind(conversation_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.map(|(v,)| v).unwrap_or(false))
}

/// Atomically bump the conversation `key_version` and purge every existing
/// `group_key_envelopes` row for that conversation. The caller is expected to
/// then broadcast a `GroupKeyRotationRequested` event so that one of the
/// remaining members regenerates and re-distributes the AES group key.
///
/// Returns the new key_version.
pub async fn bump_key_version_and_purge_envelopes(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<i32, sqlx::Error> {
    let mut tx = pool.begin().await?;

    let row: (i32,) = sqlx::query_as(
        "UPDATE conversations SET key_version = key_version + 1 \
         WHERE id = $1 RETURNING key_version",
    )
    .bind(conversation_id)
    .fetch_one(&mut *tx)
    .await?;

    sqlx::query("DELETE FROM group_key_envelopes WHERE conversation_id = $1")
        .bind(conversation_id)
        .execute(&mut *tx)
        .await?;

    // We intentionally leave rows in `group_keys` alone — they only carry the
    // sentinel "__envelope__" placeholder and the version number, which lets
    // existing duplicate-version protection (UNIQUE(conversation_id,
    // key_version)) continue to work for the next rotation upload. Old
    // envelopes carry the actual ciphertext and are gone.

    tx.commit().await?;
    Ok(row.0)
}

/// Get the current key_version for a conversation. Returns None if the row is
/// missing.
pub async fn get_key_version(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Option<i32>, sqlx::Error> {
    let row: Option<(i32,)> = sqlx::query_as("SELECT key_version FROM conversations WHERE id = $1")
        .bind(conversation_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(v,)| v))
}
