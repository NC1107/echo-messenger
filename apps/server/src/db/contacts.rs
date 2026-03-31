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
