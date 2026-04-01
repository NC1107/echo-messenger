//! Reaction and read receipt database queries.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, Serialize)]
pub struct ReactionRow {
    pub id: Uuid,
    pub message_id: Uuid,
    pub user_id: Uuid,
    pub emoji: String,
    pub created_at: DateTime<Utc>,
}

/// Add a reaction to a message. Returns the reaction row.
pub async fn add_reaction(
    pool: &PgPool,
    message_id: Uuid,
    user_id: Uuid,
    emoji: &str,
) -> Result<ReactionRow, sqlx::Error> {
    sqlx::query_as::<_, ReactionRow>(
        "INSERT INTO reactions (message_id, user_id, emoji) VALUES ($1, $2, $3) \
         ON CONFLICT (message_id, user_id, emoji) DO UPDATE SET created_at = reactions.created_at \
         RETURNING id, message_id, user_id, emoji, created_at",
    )
    .bind(message_id)
    .bind(user_id)
    .bind(emoji)
    .fetch_one(pool)
    .await
}

/// Remove a reaction. Returns true if a row was deleted.
pub async fn remove_reaction(
    pool: &PgPool,
    message_id: Uuid,
    user_id: Uuid,
    emoji: &str,
) -> Result<bool, sqlx::Error> {
    let result =
        sqlx::query("DELETE FROM reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3")
            .bind(message_id)
            .bind(user_id)
            .bind(emoji)
            .execute(pool)
            .await?;
    Ok(result.rows_affected() > 0)
}

/// Get the conversation_id for a given message.
pub async fn get_message_conversation_id(
    pool: &PgPool,
    message_id: Uuid,
) -> Result<Option<Uuid>, sqlx::Error> {
    let row: Option<(Uuid,)> = sqlx::query_as("SELECT conversation_id FROM messages WHERE id = $1")
        .bind(message_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(id,)| id))
}

/// Update or insert a read receipt for a user in a conversation.
pub async fn mark_read(
    pool: &PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO read_receipts (conversation_id, user_id, last_read_at) \
         VALUES ($1, $2, now()) \
         ON CONFLICT (conversation_id, user_id) DO UPDATE SET last_read_at = now()",
    )
    .bind(conversation_id)
    .bind(user_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Get the unread message count for a user in a specific conversation.
#[allow(dead_code)]
pub async fn get_unread_count(
    pool: &PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
) -> Result<i64, sqlx::Error> {
    let row: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM messages m \
         WHERE m.conversation_id = $1 \
           AND m.sender_id != $2 \
           AND m.created_at > COALESCE( \
               (SELECT last_read_at FROM read_receipts \
                WHERE conversation_id = $1 AND user_id = $2), \
               '1970-01-01'::timestamptz \
           )",
    )
    .bind(conversation_id)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}
