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
    pub reply_to_id: Option<Uuid>,
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
    pub reply_to_id: Option<Uuid>,
    pub reply_to_content: Option<String>,
    pub reply_to_username: Option<String>,
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

    // Find existing DM conversation where both users are members and no third member exists
    let existing: Option<(Uuid,)> = sqlx::query_as(
        "SELECT cm1.conversation_id \
         FROM conversation_members cm1 \
         JOIN conversation_members cm2 ON cm1.conversation_id = cm2.conversation_id \
         WHERE cm1.user_id = $1 AND cm2.user_id = $2 \
           AND NOT EXISTS ( \
               SELECT 1 FROM conversation_members cm3 \
               WHERE cm3.conversation_id = cm1.conversation_id \
                 AND cm3.user_id != $1 AND cm3.user_id != $2 \
           ) \
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

    // Create new DM conversation with encryption enabled by default.
    let conv: (Uuid,) = sqlx::query_as(
        "INSERT INTO conversations (kind, is_encrypted) VALUES ('direct', true) RETURNING id",
    )
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
    reply_to_id: Option<Uuid>,
) -> Result<MessageRow, sqlx::Error> {
    sqlx::query_as::<_, MessageRow>(
        "INSERT INTO messages (conversation_id, channel_id, sender_id, content, reply_to_id) \
         VALUES ($1, $2, $3, $4, $5) \
         RETURNING id, conversation_id, channel_id, sender_id, content, created_at, delivered, \
                   reply_to_id",
    )
    .bind(conversation_id)
    .bind(channel_id)
    .bind(sender_id)
    .bind(content)
    .bind(reply_to_id)
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
    // Single query handles both cursor and non-cursor cases via optional $3 param.
    sqlx::query_as::<_, MessageWithSender>(
        "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, \
                u.username AS sender_username, \
                m.content, m.created_at, m.edited_at, m.reply_to_id, \
                rm.content AS reply_to_content, \
                ru.username AS reply_to_username \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN messages rm ON rm.id = m.reply_to_id \
         LEFT JOIN users ru ON ru.id = rm.sender_id \
         WHERE m.conversation_id = $1 \
           AND ($2::uuid IS NULL OR m.channel_id = $2) \
           AND ($3::timestamptz IS NULL OR m.created_at < $3) \
           AND m.deleted_at IS NULL \
         ORDER BY m.created_at DESC \
         LIMIT $4",
    )
    .bind(conversation_id)
    .bind(channel_id)
    .bind(before)
    .bind(limit)
    .fetch_all(pool)
    .await
}

pub async fn get_undelivered(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Vec<MessageWithSender>, sqlx::Error> {
    sqlx::query_as::<_, MessageWithSender>(
        "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, \
                u.username AS sender_username, \
                m.content, m.created_at, m.edited_at, m.reply_to_id, \
                rm.content AS reply_to_content, \
                ru.username AS reply_to_username \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN messages rm ON rm.id = m.reply_to_id \
         LEFT JOIN users ru ON ru.id = rm.sender_id \
         JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = $1 \
         WHERE m.sender_id != $1 AND m.delivered = false AND m.deleted_at IS NULL \
         ORDER BY m.created_at ASC \
         LIMIT 200",
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

pub async fn search_messages(
    pool: &PgPool,
    conversation_id: Uuid,
    query: &str,
    limit: i64,
) -> Result<Vec<MessageWithSender>, sqlx::Error> {
    sqlx::query_as::<_, MessageWithSender>(
        "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, \
                u.username AS sender_username, \
                m.content, m.created_at, m.edited_at, m.reply_to_id, \
                rm.content AS reply_to_content, \
                ru.username AS reply_to_username \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN messages rm ON rm.id = m.reply_to_id \
         LEFT JOIN users ru ON ru.id = rm.sender_id \
         WHERE m.conversation_id = $1 \
           AND m.deleted_at IS NULL \
           AND to_tsvector('english', m.content) @@ plainto_tsquery('english', $2) \
         ORDER BY m.created_at DESC \
         LIMIT $3",
    )
    .bind(conversation_id)
    .bind(query)
    .bind(limit)
    .fetch_all(pool)
    .await
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct GlobalSearchResult {
    pub message_id: Uuid,
    pub conversation_id: Uuid,
    pub sender_username: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
}

/// Search messages across ALL conversations the user is a member of.
/// Uses the existing GIN full-text search index on `messages.content`.
pub async fn search_messages_global(
    pool: &PgPool,
    user_id: Uuid,
    query: &str,
    limit: i64,
) -> Result<Vec<GlobalSearchResult>, sqlx::Error> {
    sqlx::query_as::<_, GlobalSearchResult>(
        "SELECT m.id AS message_id, m.conversation_id, \
                u.username AS sender_username, \
                m.content, m.created_at \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         JOIN conversation_members cm ON cm.conversation_id = m.conversation_id \
              AND cm.user_id = $1 \
         WHERE m.deleted_at IS NULL \
           AND to_tsvector('english', m.content) @@ plainto_tsquery('english', $2) \
         ORDER BY m.created_at DESC \
         LIMIT $3",
    )
    .bind(user_id)
    .bind(query)
    .bind(limit)
    .fetch_all(pool)
    .await
}

/// Look up reply context (content and username) for a given reply_to message ID.
pub async fn lookup_reply_context(
    pool: &PgPool,
    reply_to_id: Uuid,
) -> Result<Option<(String, String)>, sqlx::Error> {
    sqlx::query_as::<_, (String, String)>(
        "SELECT m.content, u.username \
         FROM messages m JOIN users u ON u.id = m.sender_id \
         WHERE m.id = $1",
    )
    .bind(reply_to_id)
    .fetch_optional(pool)
    .await
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

pub async fn set_mute_status(
    pool: &PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
    is_muted: bool,
) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
        "UPDATE conversation_members SET is_muted = $1 \
         WHERE conversation_id = $2 AND user_id = $3",
    )
    .bind(is_muted)
    .bind(conversation_id)
    .bind(user_id)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() > 0)
}

// ---------------------------------------------------------------------------
// Message pinning
// ---------------------------------------------------------------------------

/// Pin a message. Sets pinned_by_id and pinned_at on the message row.
/// Returns the conversation_id if the pin was successful, None if message not
/// found or does not belong to the given conversation.
pub async fn pin_message(
    pool: &PgPool,
    message_id: Uuid,
    user_id: Uuid,
    conversation_id: Uuid,
) -> Result<Option<Uuid>, sqlx::Error> {
    let row: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE messages SET pinned_by_id = $2, pinned_at = now() \
         WHERE id = $1 AND conversation_id = $3 AND deleted_at IS NULL \
         RETURNING conversation_id",
    )
    .bind(message_id)
    .bind(user_id)
    .bind(conversation_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(conv_id,)| conv_id))
}

/// Unpin a message. Clears pinned_by_id and pinned_at.
/// Only unpins if the message belongs to the given conversation.
/// Returns the conversation_id if the unpin was successful, None if message not found,
/// not pinned, or does not belong to the specified conversation.
pub async fn unpin_message(
    pool: &PgPool,
    message_id: Uuid,
    conversation_id: Uuid,
) -> Result<Option<Uuid>, sqlx::Error> {
    let row: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE messages SET pinned_by_id = NULL, pinned_at = NULL \
         WHERE id = $1 AND conversation_id = $2 AND pinned_at IS NOT NULL \
         AND deleted_at IS NULL \
         RETURNING conversation_id",
    )
    .bind(message_id)
    .bind(conversation_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(conv_id,)| conv_id))
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct PinnedMessageRow {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub sender_id: Uuid,
    pub sender_username: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
    pub pinned_by_id: Option<Uuid>,
    pub pinned_by_username: Option<String>,
    pub pinned_at: Option<DateTime<Utc>>,
}

/// Get all pinned messages for a conversation, ordered by pinned_at DESC.
pub async fn get_pinned_messages(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Vec<PinnedMessageRow>, sqlx::Error> {
    sqlx::query_as::<_, PinnedMessageRow>(
        "SELECT m.id, m.conversation_id, m.sender_id, \
                u.username AS sender_username, \
                m.content, m.created_at, \
                m.pinned_by_id, \
                pu.username AS pinned_by_username, \
                m.pinned_at \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN users pu ON pu.id = m.pinned_by_id \
         WHERE m.conversation_id = $1 \
           AND m.pinned_at IS NOT NULL \
           AND m.deleted_at IS NULL \
         ORDER BY m.pinned_at DESC",
    )
    .bind(conversation_id)
    .fetch_all(pool)
    .await
}

// ---------------------------------------------------------------------------
// Multi-device per-device ciphertext storage
// ---------------------------------------------------------------------------

/// Store per-device ciphertexts for a message (multi-device encrypted delivery).
pub async fn store_device_contents(
    pool: &PgPool,
    message_id: Uuid,
    entries: &[(i32, &str)],
) -> Result<(), sqlx::Error> {
    if entries.is_empty() {
        return Ok(());
    }
    // Build a batch insert: INSERT INTO ... VALUES ($1,$2,$3), ($1,$4,$5), ...
    let mut query = String::from(
        "INSERT INTO message_device_contents (message_id, device_id, content) VALUES ",
    );
    let mut param_idx = 2; // $1 = message_id
    for (i, _) in entries.iter().enumerate() {
        if i > 0 {
            query.push_str(", ");
        }
        query.push_str(&format!("($1, ${}, ${})", param_idx, param_idx + 1));
        param_idx += 2;
    }
    query.push_str(" ON CONFLICT (message_id, device_id) DO NOTHING");

    let mut q = sqlx::query(&query).bind(message_id);
    for (device_id, content) in entries {
        q = q.bind(device_id).bind(*content);
    }
    q.execute(pool).await?;
    Ok(())
}

/// Fetch the per-device ciphertext for a specific device.
pub async fn get_device_content(
    pool: &PgPool,
    message_id: Uuid,
    device_id: i32,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT content FROM message_device_contents \
         WHERE message_id = $1 AND device_id = $2",
    )
    .bind(message_id)
    .bind(device_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(c,)| c))
}
