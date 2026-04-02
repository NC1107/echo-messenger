//! Message queue database queries.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct MessageRow {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub channel_id: Option<Uuid>,
    pub sender_id: Uuid,
    pub content: String,
    pub created_at: DateTime<Utc>,
    pub delivered: bool,
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct MessageWithSender {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub channel_id: Option<Uuid>,
    pub sender_id: Uuid,
    pub sender_username: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
    pub edited_at: Option<DateTime<Utc>>,
}

#[derive(Debug, sqlx::FromRow)]
pub struct ConversationSecurityRow {
    pub kind: String,
    pub is_encrypted: bool,
}

pub async fn find_or_create_dm_conversation(
    pool: &PgPool,
    user_a: Uuid,
    user_b: Uuid,
) -> Result<Uuid, sqlx::Error> {
    let mut tx = pool.begin().await?;

    // Find existing DM conversation where both users are members and only 2 members total
    let existing: Option<(Uuid,)> = sqlx::query_as(
        "SELECT cm1.conversation_id \
         FROM conversation_members cm1 \
         JOIN conversation_members cm2 ON cm1.conversation_id = cm2.conversation_id \
         WHERE cm1.user_id = $1 AND cm2.user_id = $2 \
           AND (SELECT COUNT(*) FROM conversation_members cm3 \
                WHERE cm3.conversation_id = cm1.conversation_id) = 2 \
         LIMIT 1",
    )
    .bind(user_a)
    .bind(user_b)
    .fetch_optional(&mut *tx)
    .await?;

    if let Some(row) = existing {
        tx.commit().await?;
        return Ok(row.0);
    }

    // Create new conversation
    let conv: (Uuid,) = sqlx::query_as("INSERT INTO conversations DEFAULT VALUES RETURNING id")
        .fetch_one(&mut *tx)
        .await?;

    let conv_id = conv.0;

    // Add both members
    sqlx::query("INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1, $2)")
        .bind(conv_id)
        .bind(user_a)
        .execute(&mut *tx)
        .await?;

    sqlx::query("INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1, $2)")
        .bind(conv_id)
        .bind(user_b)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(conv_id)
}

pub async fn store_message(
    pool: &PgPool,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
    sender_id: Uuid,
    content: &str,
) -> Result<MessageRow, sqlx::Error> {
    sqlx::query_as::<_, MessageRow>(
        "INSERT INTO messages (conversation_id, channel_id, sender_id, content) \
         VALUES ($1, $2, $3, $4) \
         RETURNING id, conversation_id, channel_id, sender_id, content, created_at, delivered",
    )
    .bind(conversation_id)
    .bind(channel_id)
    .bind(sender_id)
    .bind(content)
    .fetch_one(pool)
    .await
}

pub async fn get_messages(
    pool: &PgPool,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
    before: Option<DateTime<Utc>>,
    limit: i64,
) -> Result<Vec<MessageWithSender>, sqlx::Error> {
    match before {
        Some(cursor) => {
            sqlx::query_as::<_, MessageWithSender>(
                "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, u.username AS sender_username, \
                        m.content, m.created_at, m.edited_at \
                 FROM messages m \
                 JOIN users u ON u.id = m.sender_id \
                 WHERE m.conversation_id = $1 \
                   AND ($2::uuid IS NULL OR m.channel_id = $2) \
                   AND m.created_at < $3 \
                   AND m.deleted_at IS NULL \
                 ORDER BY m.created_at DESC \
                 LIMIT $4",
            )
            .bind(conversation_id)
            .bind(channel_id)
            .bind(cursor)
            .bind(limit)
            .fetch_all(pool)
            .await
        }
        None => {
            sqlx::query_as::<_, MessageWithSender>(
                "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, u.username AS sender_username, \
                        m.content, m.created_at, m.edited_at \
                 FROM messages m \
                 JOIN users u ON u.id = m.sender_id \
                 WHERE m.conversation_id = $1 \
                   AND ($2::uuid IS NULL OR m.channel_id = $2) \
                   AND m.deleted_at IS NULL \
                 ORDER BY m.created_at DESC \
                 LIMIT $3",
            )
            .bind(conversation_id)
            .bind(channel_id)
            .bind(limit)
            .fetch_all(pool)
            .await
        }
    }
}

pub async fn get_undelivered(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Vec<MessageWithSender>, sqlx::Error> {
    sqlx::query_as::<_, MessageWithSender>(
        "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, u.username AS sender_username, \
                m.content, m.created_at, m.edited_at \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = $1 \
         WHERE m.sender_id != $1 AND m.delivered = false AND m.deleted_at IS NULL \
         ORDER BY m.created_at ASC",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await
}

pub async fn mark_delivered(pool: &PgPool, message_ids: &[Uuid]) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE messages SET delivered = true WHERE id = ANY($1)")
        .bind(message_ids)
        .execute(pool)
        .await?;
    Ok(())
}

/// Soft-delete a message. Only the sender can delete their own message.
/// Returns the conversation_id if the delete was successful, None if no matching row found.
pub async fn delete_message(
    pool: &PgPool,
    message_id: Uuid,
    sender_id: Uuid,
) -> Result<Option<Uuid>, sqlx::Error> {
    let row: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE messages SET deleted_at = now() \
         WHERE id = $1 AND sender_id = $2 AND deleted_at IS NULL \
         RETURNING conversation_id",
    )
    .bind(message_id)
    .bind(sender_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|(conv_id,)| conv_id))
}

/// Edit a message's content. Only the sender can edit their own message.
/// Returns the conversation_id if the edit was successful, None if no matching row found.
pub async fn edit_message(
    pool: &PgPool,
    message_id: Uuid,
    sender_id: Uuid,
    new_content: &str,
) -> Result<Option<(Uuid, DateTime<Utc>)>, sqlx::Error> {
    let row: Option<(Uuid, DateTime<Utc>)> = sqlx::query_as(
        "UPDATE messages SET content = $3, edited_at = now() \
         WHERE id = $1 AND sender_id = $2 AND deleted_at IS NULL \
         RETURNING conversation_id, edited_at",
    )
    .bind(message_id)
    .bind(sender_id)
    .bind(new_content)
    .fetch_optional(pool)
    .await?;

    Ok(row)
}

pub async fn set_conversation_encrypted(
    pool: &PgPool,
    conversation_id: Uuid,
    is_encrypted: bool,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE conversations SET is_encrypted = $1 WHERE id = $2")
        .bind(is_encrypted)
        .bind(conversation_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn get_conversation_security(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Option<ConversationSecurityRow>, sqlx::Error> {
    sqlx::query_as::<_, ConversationSecurityRow>(
        "SELECT kind, is_encrypted FROM conversations WHERE id = $1",
    )
    .bind(conversation_id)
    .fetch_optional(pool)
    .await
}
