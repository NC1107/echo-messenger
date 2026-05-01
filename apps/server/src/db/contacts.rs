//! Contact database queries.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

/// Hard cap on the number of rows returned by contact list queries.
/// Prevents unbounded memory use when a user has an unusually large contact
/// list. Pagination can be added in a follow-up; for now a single hard cap
/// is sufficient for any realistic use-case.
pub const LIST_CONTACTS_LIMIT: i64 = 1_000;
pub const LIST_BLOCKED_LIMIT: i64 = 1_000;
pub const LIST_PENDING_LIMIT: i64 = 1_000;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct ContactRow {
    pub id: Uuid,
    pub user_id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    /// Most recent device activity for this contact. `None` if the contact has
    /// never connected or has set their presence to "invisible".
    pub last_seen: Option<DateTime<Utc>>,
}

/// Create a contact request. Uses a transaction to prevent a TOCTOU race
/// between the user lookup, block check, and insert.
pub async fn create_contact_request(
    pool: &PgPool,
    requester_id: Uuid,
    target_username: &str,
) -> Result<Uuid, sqlx::Error> {
    let mut tx = pool.begin().await?;

    let target = sqlx::query_as::<_, (Uuid,)>("SELECT id FROM users WHERE username = $1")
        .bind(target_username)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;

    let target_id = target.0;

    // Check if either party has blocked the other -- return a generic error
    // (same as "user not found") to avoid leaking block status.
    let blocked: (bool,) = sqlx::query_as(
        "SELECT EXISTS(\
            SELECT 1 FROM blocked_users \
            WHERE (blocker_id = $1 AND blocked_id = $2) \
               OR (blocker_id = $2 AND blocked_id = $1)\
        )",
    )
    .bind(requester_id)
    .bind(target_id)
    .fetch_one(&mut *tx)
    .await?;

    if blocked.0 {
        return Err(sqlx::Error::RowNotFound);
    }

    let row: (Uuid,) = sqlx::query_as(
        "INSERT INTO contacts (requester_id, target_id) VALUES ($1, $2) RETURNING id",
    )
    .bind(requester_id)
    .bind(target_id)
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;
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
                c.created_at, \
                CASE WHEN u.presence_status = 'invisible' THEN NULL \
                     ELSE (SELECT MAX(ik.last_seen) \
                           FROM identity_keys ik \
                           WHERE ik.user_id = u.id AND ik.revoked_at IS NULL) \
                END AS last_seen \
         FROM contacts c \
         JOIN users u ON u.id = CASE WHEN c.requester_id = $1 THEN c.target_id ELSE c.requester_id END \
         WHERE (c.requester_id = $1 OR c.target_id = $1) AND c.status = 'accepted' \
         ORDER BY u.username \
         LIMIT $2",
    )
    .bind(user_id)
    .bind(LIST_CONTACTS_LIMIT)
    .fetch_all(pool)
    .await
}

/// Return just the user IDs of accepted contacts for a given user.
pub async fn list_contact_user_ids(pool: &PgPool, user_id: Uuid) -> Result<Vec<Uuid>, sqlx::Error> {
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT CASE WHEN requester_id = $1 THEN target_id ELSE requester_id END \
         FROM contacts \
         WHERE (requester_id = $1 OR target_id = $1) AND status = 'accepted'",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
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
                c.created_at, \
                NULL::TIMESTAMPTZ AS last_seen \
         FROM contacts c \
         JOIN users u ON u.id = c.requester_id \
         WHERE c.target_id = $1 AND c.status = 'pending' \
         ORDER BY c.created_at DESC \
         LIMIT $2",
    )
    .bind(user_id)
    .bind(LIST_PENDING_LIMIT)
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
         ORDER BY b.created_at DESC \
         LIMIT $2",
    )
    .bind(blocker_id)
    .bind(LIST_BLOCKED_LIMIT)
    .fetch_all(pool)
    .await
}

/// Decline (delete) a pending contact request where `declining_user_id` is the target.
/// Returns true if a row was actually deleted.
pub async fn decline_contact_request(
    pool: &PgPool,
    contact_id: Uuid,
    declining_user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result =
        sqlx::query("DELETE FROM contacts WHERE id = $1 AND target_id = $2 AND status = 'pending'")
            .bind(contact_id)
            .bind(declining_user_id)
            .execute(pool)
            .await?;

    Ok(result.rows_affected() > 0)
}

/// Check if either user has blocked the other (bidirectional check in a single query).
pub async fn is_either_blocked(
    pool: &PgPool,
    user_a: Uuid,
    user_b: Uuid,
) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS(\
            SELECT 1 FROM blocked_users \
            WHERE (blocker_id = $1 AND blocked_id = $2) \
               OR (blocker_id = $2 AND blocked_id = $1)\
        )",
    )
    .bind(user_a)
    .bind(user_b)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
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

/// Return the set of user IDs (from `candidate_ids`) that have blocked `target_id`.
pub async fn get_blockers_of(
    pool: &PgPool,
    candidate_ids: &[Uuid],
    target_id: Uuid,
) -> Result<Vec<Uuid>, sqlx::Error> {
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT blocker_id FROM blocked_users \
         WHERE blocker_id = ANY($1) AND blocked_id = $2",
    )
    .bind(candidate_ids)
    .bind(target_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
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
