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
    /// Device that originated the message. `None` for legacy rows that
    /// predate multi-device tracking (#557).
    pub sender_device_id: Option<i32>,
    pub content: String,
    pub created_at: DateTime<Utc>,
    pub delivered: bool,
    pub reply_to_id: Option<Uuid>,
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct MessageWithSender {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub channel_id: Option<Uuid>,
    pub sender_id: Uuid,
    /// Device that originated the message. `None` for legacy rows that
    /// predate multi-device tracking (#557).
    pub sender_device_id: Option<i32>,
    pub sender_username: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
    pub edited_at: Option<DateTime<Utc>>,
    pub reply_to_id: Option<Uuid>,
    pub reply_to_content: Option<String>,
    pub reply_to_username: Option<String>,
    pub reply_count: i64,
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
    // Canonical order: the smaller UUID is always user_lo so the unique
    // constraint on (user_lo, user_hi) is independent of argument order.
    let (lo, hi) = if user_a < user_b {
        (user_a, user_b)
    } else {
        (user_b, user_a)
    };

    // Fast path: the canonical lookup table already has an entry.
    let existing: Option<(Uuid,)> = sqlx::query_as(
        "SELECT conversation_id FROM direct_conversations \
         WHERE user_lo = $1 AND user_hi = $2",
    )
    .bind(lo)
    .bind(hi)
    .fetch_optional(pool)
    .await?;

    if let Some(row) = existing {
        return Ok(row.0);
    }

    // Slow path: create the conversation and claim the canonical slot.
    // Acquire a transaction-scoped advisory lock keyed on the canonical
    // (lo, hi) pair so concurrent creators for the same user pair serialize
    // here rather than contending at the UNIQUE constraint level.  We
    // concatenate the lexicographically smaller UUID first so both argument
    // orderings hash to the same i64.  `pg_advisory_xact_lock` (not the
    // `try_` variant) blocks until the lock is available and releases
    // automatically when the transaction ends.
    let mut tx = pool.begin().await?;

    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1::text || $2::text))")
        .bind(lo)
        .bind(hi)
        .execute(&mut *tx)
        .await?;

    // Re-check inside the tx: another creator may have committed while we
    // were waiting for the lock, in which case we can take the fast path.
    let existing_in_tx: Option<(Uuid,)> = sqlx::query_as(
        "SELECT conversation_id FROM direct_conversations \
         WHERE user_lo = $1 AND user_hi = $2",
    )
    .bind(lo)
    .bind(hi)
    .fetch_optional(&mut *tx)
    .await?;

    if let Some(row) = existing_in_tx {
        tx.rollback().await?;
        return Ok(row.0);
    }

    // Create the conversation row.
    let conv: (Uuid,) = sqlx::query_as(
        "INSERT INTO conversations (kind, is_encrypted) VALUES ('direct', true) RETURNING id",
    )
    .fetch_one(&mut *tx)
    .await?;
    let conv_id = conv.0;

    // Add both members.
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

    // Atomically claim the (lo, hi) slot.  If another concurrent request
    // already committed a row for this pair, the DO UPDATE is a no-op that
    // returns the *existing* conversation_id, letting us discard the one we
    // just created by rolling back.
    let winner: (Uuid,) = sqlx::query_as(
        "INSERT INTO direct_conversations (user_lo, user_hi, conversation_id) \
         VALUES ($1, $2, $3) \
         ON CONFLICT (user_lo, user_hi) \
         DO UPDATE SET conversation_id = direct_conversations.conversation_id \
         RETURNING conversation_id",
    )
    .bind(lo)
    .bind(hi)
    .bind(conv_id)
    .fetch_one(&mut *tx)
    .await?;

    if winner.0 != conv_id {
        // A concurrent request won the race. Roll back to avoid orphan rows,
        // then return the already-committed conversation.
        tx.rollback().await?;
        return Ok(winner.0);
    }

    tx.commit().await?;
    Ok(conv_id)
}

/// Insert a new message, optionally linked to a parent via `reply_to_id`.
///
/// Contract for `reply_to_id` (#519): when `Some`, the parent message must
/// exist in the same conversation **and** not be soft-deleted.  When the
/// parent is missing, deleted, or belongs to a different conversation, the
/// INSERT is suppressed and `sqlx::Error::RowNotFound` is returned so the
/// caller can translate that into a 404 / WS error frame instead of leaking
/// content across conversations.
#[allow(clippy::too_many_arguments)]
pub async fn store_message(
    pool: &PgPool,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
    sender_id: Uuid,
    sender_device_id: Option<i32>,
    content: &str,
    reply_to_id: Option<Uuid>,
    ttl_seconds: Option<i64>,
) -> Result<MessageRow, sqlx::Error> {
    let expires_at: Option<DateTime<Utc>> =
        ttl_seconds.map(|s| Utc::now() + chrono::Duration::seconds(s));
    sqlx::query_as::<_, MessageRow>(
        "WITH parent AS ( \
             SELECT id FROM messages \
             WHERE id = $5 AND conversation_id = $1 AND deleted_at IS NULL \
         ) \
         INSERT INTO messages (conversation_id, channel_id, sender_id, content, reply_to_id, expires_at, sender_device_id) \
         SELECT $1, $2, $3, $4, \
                CASE WHEN $5::uuid IS NULL THEN NULL \
                     ELSE (SELECT id FROM parent) END, \
                $6, $7 \
         WHERE $5::uuid IS NULL OR EXISTS (SELECT 1 FROM parent) \
         RETURNING id, conversation_id, channel_id, sender_id, sender_device_id, \
                   content, created_at, delivered, reply_to_id, expires_at",
    )
    .bind(conversation_id)
    .bind(channel_id)
    .bind(sender_id)
    .bind(content)
    .bind(reply_to_id)
    .bind(expires_at)
    .bind(sender_device_id)
    .fetch_one(pool)
    .await
}

#[allow(clippy::too_many_arguments)]
pub async fn get_messages(
    pool: &PgPool,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
    before: Option<DateTime<Utc>>,
    limit: i64,
    requesting_user_id: Uuid,
    requesting_device_id: Option<i32>,
) -> Result<Vec<MessageWithSender>, sqlx::Error> {
    // Single query handles both cursor and non-cursor cases via optional $3 param.
    // #557: when device_id is supplied, COALESCE per-device ciphertext over
    // the canonical content. reply_count via LEFT JOIN LATERAL matches the
    // shape used by search_messages / get_thread_replies.
    sqlx::query_as::<_, MessageWithSender>(
        "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, \
                m.sender_device_id, \
                u.username AS sender_username, \
                COALESCE(mdc.content, m.content) AS content, \
                m.created_at, m.edited_at, m.reply_to_id, \
                rm.content AS reply_to_content, \
                ru.username AS reply_to_username, \
                COALESCE(rc.cnt, 0) AS reply_count \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN messages rm ON rm.id = m.reply_to_id AND rm.conversation_id = m.conversation_id \
         LEFT JOIN users ru ON ru.id = rm.sender_id \
         LEFT JOIN LATERAL ( \
             SELECT COUNT(*) AS cnt FROM messages r \
             WHERE r.reply_to_id = m.id AND r.deleted_at IS NULL \
         ) rc ON true \
         LEFT JOIN message_device_contents mdc \
                ON $5::int IS NOT NULL \
               AND mdc.message_id = m.id \
               AND mdc.recipient_user_id = $6 \
               AND mdc.device_id = $5 \
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
    .bind(requesting_device_id)
    .bind(requesting_user_id)
    .fetch_all(pool)
    .await
}

/// Page size for offline-replay batches.  Picked so a single batch fits
/// comfortably in the WS outbound mpsc(256) without immediate backpressure
/// (#634), while still exercising the ack queue under realistic backlogs.
pub const UNDELIVERED_PAGE_SIZE: i64 = 200;

/// Fetch undelivered messages, optionally after a `(created_at, id)` cursor.
/// Composite cursor handles ties when multiple messages share a timestamp;
/// using `created_at` alone would skip same-tick siblings on the next page.
/// Callers loop with the cursor until the batch returns
/// < UNDELIVERED_PAGE_SIZE rows.
pub async fn get_undelivered(
    pool: &PgPool,
    user_id: Uuid,
    after_cursor: Option<(DateTime<Utc>, Uuid)>,
) -> Result<Vec<MessageWithSender>, sqlx::Error> {
    let (after_ts, after_id): (Option<DateTime<Utc>>, Option<Uuid>) = match after_cursor {
        Some((ts, id)) => (Some(ts), Some(id)),
        None => (None, None),
    };
    // reply_count is computed via a single aggregating subquery joined once
    // (O(N+M)) rather than a LATERAL correlated subquery that re-executes for
    // every returned row (O(N*M)).  Fixes #638.
    sqlx::query_as::<_, MessageWithSender>(
        "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, \
                m.sender_device_id, \
                u.username AS sender_username, \
                m.content, m.created_at, m.edited_at, m.reply_to_id, \
                rm.content AS reply_to_content, \
                ru.username AS reply_to_username, \
                COALESCE(rc.reply_count, 0) AS reply_count \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN messages rm ON rm.id = m.reply_to_id AND rm.conversation_id = m.conversation_id \
         LEFT JOIN users ru ON ru.id = rm.sender_id \
         LEFT JOIN ( \
             SELECT reply_to_id, COUNT(*) AS reply_count \
             FROM messages \
             WHERE reply_to_id IS NOT NULL AND deleted_at IS NULL \
             GROUP BY reply_to_id \
         ) rc ON rc.reply_to_id = m.id \
         JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = $1 \
                  AND cm.is_removed = false \
         WHERE m.sender_id != $1 AND m.delivered = false AND m.deleted_at IS NULL \
                  AND ($2::timestamptz IS NULL OR (m.created_at, m.id) > ($2, $3)) \
         ORDER BY m.created_at ASC, m.id ASC \
         LIMIT $4",
    )
    .bind(user_id)
    .bind(after_ts)
    .bind(after_id)
    .bind(UNDELIVERED_PAGE_SIZE)
    .fetch_all(pool)
    .await
}

/// Delete all messages whose `expires_at` is in the past.
///
/// Returns the (id, conversation_id) pairs that were deleted so the caller
/// can broadcast `message_expired` events to online users.
pub async fn cleanup_expired_messages(pool: &PgPool) -> Result<Vec<(Uuid, Uuid)>, sqlx::Error> {
    let rows: Vec<(Uuid, Uuid)> = sqlx::query_as(
        "DELETE FROM messages \
         WHERE expires_at IS NOT NULL AND expires_at <= NOW() \
         RETURNING id, conversation_id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// Fetch the disappearing TTL (in seconds) configured for a conversation,
/// if any. Returns None when disappearing messages are disabled.
pub async fn get_conversation_ttl(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Option<i64>, sqlx::Error> {
    let row: Option<(Option<i32>,)> =
        sqlx::query_as("SELECT disappearing_ttl_seconds FROM conversations WHERE id = $1")
            .bind(conversation_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(v,)| v).map(|v| v as i64))
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

/// Look up the conversation security flags for a message that the caller
/// claims to own. Returns `None` when the message does not exist, has been
/// soft-deleted, or was sent by a different user. Used to gate edits on
/// encrypted conversations (#582) before performing the UPDATE.
pub async fn get_message_conversation_security(
    pool: &PgPool,
    message_id: Uuid,
    sender_id: Uuid,
) -> Result<Option<MessageConversationSecurity>, sqlx::Error> {
    sqlx::query_as::<_, MessageConversationSecurity>(
        "SELECT m.conversation_id, c.is_encrypted \
         FROM messages m JOIN conversations c ON c.id = m.conversation_id \
         WHERE m.id = $1 AND m.sender_id = $2 AND m.deleted_at IS NULL",
    )
    .bind(message_id)
    .bind(sender_id)
    .fetch_optional(pool)
    .await
}

#[derive(Debug, sqlx::FromRow)]
pub struct MessageConversationSecurity {
    pub conversation_id: Uuid,
    pub is_encrypted: bool,
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
                m.sender_device_id, \
                u.username AS sender_username, \
                m.content, m.created_at, m.edited_at, m.reply_to_id, \
                rm.content AS reply_to_content, \
                ru.username AS reply_to_username, \
                COALESCE(rc.cnt, 0) AS reply_count \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN messages rm ON rm.id = m.reply_to_id AND rm.conversation_id = m.conversation_id \
         LEFT JOIN users ru ON ru.id = rm.sender_id \
         LEFT JOIN LATERAL ( \
             SELECT COUNT(*) AS cnt FROM messages r \
             WHERE r.reply_to_id = m.id AND r.deleted_at IS NULL \
         ) rc ON true \
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
              AND cm.user_id = $1 AND cm.is_removed = false \
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

/// Look up reply context (content and username) for a given reply_to message ID,
/// scoped to the supplied `conversation_id`.  Soft-deleted parents return `None`.
/// Cross-conversation lookups also return `None` so a sender cannot peek at
/// the content of a message in a different conversation. #519
pub async fn lookup_reply_context(
    pool: &PgPool,
    reply_to_id: Uuid,
    conversation_id: Uuid,
) -> Result<Option<(String, String)>, sqlx::Error> {
    sqlx::query_as::<_, (String, String)>(
        "SELECT m.content, u.username \
         FROM messages m JOIN users u ON u.id = m.sender_id \
         WHERE m.id = $1 AND m.conversation_id = $2 AND m.deleted_at IS NULL",
    )
    .bind(reply_to_id)
    .bind(conversation_id)
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
         WHERE conversation_id = $2 AND user_id = $3 AND is_removed = false",
    )
    .bind(is_muted)
    .bind(conversation_id)
    .bind(user_id)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() > 0)
}

/// Filter the given user IDs down to those who have NOT muted this
/// conversation. Used by the push-notification path so muted recipients are
/// not woken with an APNs alert for messages they would not see locally.
pub async fn get_unmuted_user_ids(
    pool: &PgPool,
    conversation_id: Uuid,
    user_ids: &[Uuid],
) -> Result<Vec<Uuid>, sqlx::Error> {
    if user_ids.is_empty() {
        return Ok(Vec::new());
    }
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT user_id FROM conversation_members \
         WHERE conversation_id = $1 \
           AND user_id = ANY($2) \
           AND is_muted = false \
           AND is_removed = false",
    )
    .bind(conversation_id)
    .bind(user_ids)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
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
///
/// Entries are `(recipient_user_id, device_id, ciphertext)`. Per-user device IDs
/// collide across users (every user starts at device_id=1), so the storage key
/// is scoped by recipient (#522).
pub async fn store_device_contents(
    pool: &PgPool,
    message_id: Uuid,
    entries: &[(Uuid, i32, &str)],
) -> Result<(), sqlx::Error> {
    if entries.is_empty() {
        return Ok(());
    }
    let mut query = String::from(
        "INSERT INTO message_device_contents \
         (message_id, recipient_user_id, device_id, content) VALUES ",
    );
    let mut param_idx = 2; // $1 = message_id
    for (i, _) in entries.iter().enumerate() {
        if i > 0 {
            query.push_str(", ");
        }
        query.push_str(&format!(
            "($1, ${}, ${}, ${})",
            param_idx,
            param_idx + 1,
            param_idx + 2
        ));
        param_idx += 3;
    }
    query.push_str(" ON CONFLICT (message_id, recipient_user_id, device_id) DO NOTHING");

    let mut q = sqlx::query(&query).bind(message_id);
    for (recipient_user_id, device_id, content) in entries {
        q = q.bind(recipient_user_id).bind(device_id).bind(*content);
    }
    q.execute(pool).await?;
    Ok(())
}

/// Fetch the per-device ciphertext for a specific recipient device.
pub async fn get_device_content(
    pool: &PgPool,
    message_id: Uuid,
    recipient_user_id: Uuid,
    device_id: i32,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT content FROM message_device_contents \
         WHERE message_id = $1 AND recipient_user_id = $2 AND device_id = $3",
    )
    .bind(message_id)
    .bind(recipient_user_id)
    .bind(device_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(c,)| c))
}

/// Return the subset of `message_ids` that have at least one per-device
/// ciphertext row for `recipient_user_id` across *any* of the recipient's
/// devices.  Used by offline replay to distinguish "no per-device fanout
/// happened" (legacy/group/plaintext) from "fanout happened but missed this
/// device", so the latter can be flagged as undecryptable instead of
/// silently shipping the wrong device's wire (#557).
pub async fn message_ids_with_any_device_content(
    pool: &PgPool,
    message_ids: &[Uuid],
    recipient_user_id: Uuid,
) -> Result<std::collections::HashSet<Uuid>, sqlx::Error> {
    if message_ids.is_empty() {
        return Ok(std::collections::HashSet::new());
    }
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT DISTINCT message_id FROM message_device_contents \
         WHERE message_id = ANY($1) AND recipient_user_id = $2",
    )
    .bind(message_ids)
    .bind(recipient_user_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
}

/// Fetch per-device ciphertexts for a batch of messages for a specific
/// recipient device in a single query.  Returns a map from message_id to
/// device-specific content.
///
/// Used by `deliver_undelivered_messages` to avoid N+1 queries when replaying
/// the offline queue.
pub async fn get_device_contents_batch(
    pool: &PgPool,
    message_ids: &[Uuid],
    recipient_user_id: Uuid,
    device_id: i32,
) -> Result<std::collections::HashMap<Uuid, String>, sqlx::Error> {
    if message_ids.is_empty() {
        return Ok(std::collections::HashMap::new());
    }
    let rows: Vec<(Uuid, String)> = sqlx::query_as(
        "SELECT message_id, content FROM message_device_contents \
         WHERE message_id = ANY($1) AND recipient_user_id = $2 AND device_id = $3",
    )
    .bind(message_ids)
    .bind(recipient_user_id)
    .bind(device_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().collect())
}

// ---------------------------------------------------------------------------
// Thread replies
// ---------------------------------------------------------------------------

/// Fetch all replies to a given parent message, ordered chronologically.
/// Each reply includes its own reply_count so the client can show nested thread
/// indicators.
///
/// Scoped to `conversation_id` (#519): even though `reply_to_id` should already
/// only point at messages in the same conversation after the `store_message`
/// fix, this query enforces it defensively so historical bad data cannot leak
/// across conversations on read.
pub async fn get_thread_replies(
    pool: &PgPool,
    parent_message_id: Uuid,
    conversation_id: Uuid,
    limit: i64,
) -> Result<Vec<MessageWithSender>, sqlx::Error> {
    sqlx::query_as::<_, MessageWithSender>(
        "SELECT m.id, m.conversation_id, m.channel_id, m.sender_id, \
                m.sender_device_id, \
                u.username AS sender_username, \
                m.content, m.created_at, m.edited_at, m.reply_to_id, \
                rm.content AS reply_to_content, \
                ru.username AS reply_to_username, \
                COALESCE(rc.cnt, 0) AS reply_count \
         FROM messages m \
         JOIN users u ON u.id = m.sender_id \
         LEFT JOIN messages rm ON rm.id = m.reply_to_id AND rm.conversation_id = m.conversation_id \
         LEFT JOIN users ru ON ru.id = rm.sender_id \
         LEFT JOIN LATERAL ( \
             SELECT COUNT(*) AS cnt FROM messages r \
             WHERE r.reply_to_id = m.id AND r.deleted_at IS NULL \
         ) rc ON true \
         WHERE m.reply_to_id = $1 \
           AND m.conversation_id = $2 \
           AND m.deleted_at IS NULL \
         ORDER BY m.created_at ASC \
         LIMIT $3",
    )
    .bind(parent_message_id)
    .bind(conversation_id)
    .bind(limit)
    .fetch_all(pool)
    .await
}
