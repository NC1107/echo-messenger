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

/// Create a group conversation and add the creator plus initial members.
#[allow(dead_code)]
pub async fn create_group(
    pool: &PgPool,
    creator_id: Uuid,
    name: &str,
    member_ids: &[Uuid],
) -> Result<GroupInfo, sqlx::Error> {
    let mut tx = pool.begin().await?;

    let group: GroupInfo = sqlx::query_as(
        "INSERT INTO conversations (kind, title) VALUES ('group', $1) \
         RETURNING id, title, kind, description, created_at",
    )
    .bind(name)
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
            continue; // Skip if creator is also listed
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
        "INSERT INTO conversations (kind, title, is_public, description) VALUES ('group', $1, $2, $3) \
         RETURNING id, title, kind, description, created_at",
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

/// List public groups, optionally filtered by title search.
pub async fn list_public_groups(
    pool: &PgPool,
    user_id: Uuid,
    search: Option<&str>,
) -> Result<Vec<PublicGroupRow>, sqlx::Error> {
    match search {
        Some(term) => {
            let pattern = format!("%{}%", term);
            sqlx::query_as::<_, PublicGroupRow>(
                "SELECT c.id, c.title, \
                 COUNT(cm.user_id) AS member_count, c.created_at, \
                 EXISTS(SELECT 1 FROM conversation_members cm2 \
                        WHERE cm2.conversation_id = c.id \
                        AND cm2.user_id = $2) AS is_member \
                 FROM conversations c \
                 LEFT JOIN conversation_members cm \
                   ON cm.conversation_id = c.id \
                 WHERE c.is_public = true AND c.kind = 'group' \
                   AND c.title ILIKE $1 \
                 GROUP BY c.id \
                 ORDER BY c.created_at DESC",
            )
            .bind(pattern)
            .bind(user_id)
            .fetch_all(pool)
            .await
        }
        None => {
            sqlx::query_as::<_, PublicGroupRow>(
                "SELECT c.id, c.title, \
                 COUNT(cm.user_id) AS member_count, c.created_at, \
                 EXISTS(SELECT 1 FROM conversation_members cm2 \
                        WHERE cm2.conversation_id = c.id \
                        AND cm2.user_id = $1) AS is_member \
                 FROM conversations c \
                 LEFT JOIN conversation_members cm \
                   ON cm.conversation_id = c.id \
                 WHERE c.is_public = true AND c.kind = 'group' \
                 GROUP BY c.id \
                 ORDER BY c.created_at DESC",
            )
            .bind(user_id)
            .fetch_all(pool)
            .await
        }
    }
}

/// Join a public group. Returns an error if the group is not public.
pub async fn join_public_group(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    // Check that the conversation exists and is public
    let row: Option<(bool,)> =
        sqlx::query_as("SELECT is_public FROM conversations WHERE id = $1 AND kind = 'group'")
            .bind(group_id)
            .fetch_optional(pool)
            .await?;

    match row {
        Some((true,)) => {
            sqlx::query(
                "INSERT INTO conversation_members (conversation_id, user_id, role) VALUES ($1, $2, 'member') \
                 ON CONFLICT DO NOTHING",
            )
            .bind(group_id)
            .bind(user_id)
            .execute(pool)
            .await?;
            Ok(true)
        }
        Some((false,)) => Ok(false),
        None => Ok(false),
    }
}

/// Get group info by conversation ID.
pub async fn get_group(pool: &PgPool, group_id: Uuid) -> Result<Option<GroupInfo>, sqlx::Error> {
    sqlx::query_as::<_, GroupInfo>(
        "SELECT id, title, kind, description, created_at FROM conversations WHERE id = $1 AND kind = 'group'",
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
         WHERE cm.conversation_id = $1 \
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
         WHERE conversation_id = $1 AND user_id = $2)",
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
         WHERE conversation_id = $1 AND user_id = $2",
    )
    .bind(group_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(role,)| role))
}

/// Add a member to a group.
pub async fn add_member(pool: &PgPool, group_id: Uuid, user_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO conversation_members (conversation_id, user_id, role) VALUES ($1, $2, 'member')",
    )
    .bind(group_id)
    .bind(user_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Remove a member from a group.
pub async fn remove_member(
    pool: &PgPool,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result =
        sqlx::query("DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2")
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
        sqlx::query_as("SELECT user_id FROM conversation_members WHERE conversation_id = $1")
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
            WHERE cm.user_id = $1 AND cm.role = 'owner' AND c.title = $2 AND c.is_public = true\
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
pub async fn delete_group(
    pool: &PgPool,
    group_id: Uuid,
    owner_id: Uuid,
) -> Result<bool, sqlx::Error> {
    // Verify the caller is the owner
    let role = get_member_role(pool, group_id, owner_id).await?;
    if role.as_deref() != Some("owner") {
        return Ok(false);
    }
    // Delete conversation (cascades to members, messages via FK)
    sqlx::query("DELETE FROM conversations WHERE id = $1")
        .bind(group_id)
        .execute(pool)
        .await?;
    Ok(true)
}

/// Check if a group is public.
pub async fn is_public(pool: &PgPool, group_id: Uuid) -> Result<bool, sqlx::Error> {
    let row: Option<(bool,)> = sqlx::query_as("SELECT is_public FROM conversations WHERE id = $1")
        .bind(group_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(p,)| p).unwrap_or(false))
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
