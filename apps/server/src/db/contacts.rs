//! Contact database queries.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct ContactRow {
    pub id: Uuid,
    pub user_id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub status: String,
    pub created_at: DateTime<Utc>,
}

pub async fn create_contact_request(
    pool: &PgPool,
    requester_id: Uuid,
    target_username: &str,
) -> Result<Uuid, sqlx::Error> {
    let target = sqlx::query_as::<_, (Uuid,)>("SELECT id FROM users WHERE username = $1")
        .bind(target_username)
        .fetch_optional(pool)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;

    let target_id = target.0;

    let row: (Uuid,) = sqlx::query_as(
        "INSERT INTO contacts (requester_id, target_id) VALUES ($1, $2) RETURNING id",
    )
    .bind(requester_id)
    .bind(target_id)
    .fetch_one(pool)
    .await?;

    Ok(row.0)
}

pub async fn accept_contact_request(
    pool: &PgPool,
    contact_id: Uuid,
    accepting_user_id: Uuid,
) -> Result<(), sqlx::Error> {
    let result = sqlx::query(
        "UPDATE contacts SET status = 'accepted', updated_at = now() \
         WHERE id = $1 AND target_id = $2 AND status = 'pending'",
    )
    .bind(contact_id)
    .bind(accepting_user_id)
    .execute(pool)
    .await?;

    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }

    Ok(())
}

pub async fn list_contacts(pool: &PgPool, user_id: Uuid) -> Result<Vec<ContactRow>, sqlx::Error> {
    sqlx::query_as::<_, ContactRow>(
        "SELECT c.id, \
                CASE WHEN c.requester_id = $1 THEN c.target_id ELSE c.requester_id END AS user_id, \
                u.username, \
                u.display_name, \
                u.avatar_url, \
                c.status, \
                c.created_at \
         FROM contacts c \
         JOIN users u ON u.id = CASE WHEN c.requester_id = $1 THEN c.target_id ELSE c.requester_id END \
         WHERE (c.requester_id = $1 OR c.target_id = $1) AND c.status = 'accepted' \
         ORDER BY u.username",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await
}

pub async fn list_pending_requests(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Vec<ContactRow>, sqlx::Error> {
    sqlx::query_as::<_, ContactRow>(
        "SELECT c.id, \
                c.requester_id AS user_id, \
                u.username, \
                u.display_name, \
                u.avatar_url, \
                c.status, \
                c.created_at \
         FROM contacts c \
         JOIN users u ON u.id = c.requester_id \
         WHERE c.target_id = $1 AND c.status = 'pending' \
         ORDER BY c.created_at DESC",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await
}

// ---------------------------------------------------------------------------
// Block / unblock
// ---------------------------------------------------------------------------

pub async fn block_user(
    pool: &PgPool,
    blocker_id: Uuid,
    blocked_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO blocked_users (blocker_id, blocked_id) VALUES ($1, $2) \
         ON CONFLICT DO NOTHING",
    )
    .bind(blocker_id)
    .bind(blocked_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn unblock_user(
    pool: &PgPool,
    blocker_id: Uuid,
    blocked_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result = sqlx::query("DELETE FROM blocked_users WHERE blocker_id = $1 AND blocked_id = $2")
        .bind(blocker_id)
        .bind(blocked_id)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() > 0)
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct BlockedUserRow {
    pub blocked_id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub created_at: DateTime<Utc>,
}

pub async fn list_blocked_users(
    pool: &PgPool,
    blocker_id: Uuid,
) -> Result<Vec<BlockedUserRow>, sqlx::Error> {
    sqlx::query_as::<_, BlockedUserRow>(
        "SELECT b.blocked_id, u.username, u.display_name, b.created_at \
         FROM blocked_users b \
         JOIN users u ON u.id = b.blocked_id \
         WHERE b.blocker_id = $1 \
         ORDER BY b.created_at DESC",
    )
    .bind(blocker_id)
    .fetch_all(pool)
    .await
}

/// Check if `blocker_id` has blocked `blocked_id`.
pub async fn is_blocked(
    pool: &PgPool,
    blocker_id: Uuid,
    blocked_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS(SELECT 1 FROM blocked_users WHERE blocker_id = $1 AND blocked_id = $2)",
    )
    .bind(blocker_id)
    .bind(blocked_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

pub async fn are_contacts(pool: &PgPool, user_a: Uuid, user_b: Uuid) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS( \
            SELECT 1 FROM contacts \
            WHERE status = 'accepted' \
              AND ((requester_id = $1 AND target_id = $2) \
                OR (requester_id = $2 AND target_id = $1)) \
         )",
    )
    .bind(user_a)
    .bind(user_b)
    .fetch_one(pool)
    .await?;

    Ok(row.0)
}
