//! Thread read-state + inbox queries (M3).
//!
//! Tracks the last time a user viewed each thread so the client can
//! render per-thread unread counts and an aggregated cross-group
//! threads inbox.
//!
//! Visibility is implicit — a user "sees" a thread iff they're a
//! member of the parent message's conversation. No follow/subscribe
//! table yet; follow-then-mute work belongs to a later milestone.

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// One row of the threads-inbox response. Carries enough metadata for
/// the client to render the inbox list (parent excerpt, last reply
/// time, unread count, conversation context).
#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct ThreadInboxEntry {
    /// Root message id (also the thread's stable id).
    pub thread_root_id: Uuid,
    /// Conversation the thread lives in. Used by the client to
    /// route the user back to the right place when they tap.
    pub conversation_id: Uuid,
    /// Channel id (when the parent lived in a channel — null for DMs
    /// and group conversations without channels).
    pub channel_id: Option<Uuid>,
    /// Parent author + content excerpt for the list-row preview. The
    /// excerpt is truncated to 120 chars server-side so the response
    /// stays bounded.
    pub parent_sender_username: String,
    pub parent_excerpt: String,
    /// Newest reply timestamp; drives the inbox's "X minutes ago" label
    /// and is also used for the sort.
    pub last_reply_at: DateTime<Utc>,
    /// Snippet of the most-recent reply (also truncated to 120).
    pub last_reply_excerpt: String,
    pub last_reply_sender_username: String,
    /// Total replies on this thread.
    pub reply_count: i64,
    /// Count of replies after the caller's `last_read_at` (0 when caller
    /// has no row in `thread_read_state` is replaced by reply_count —
    /// see the COALESCE in the SQL).
    pub unread_count: i64,
}

/// Inbox listing for [user_id]: every thread the user can see, with
/// unread counts. Sorted newest-reply-first.
pub async fn get_threads_inbox(
    pool: &sqlx::PgPool,
    user_id: Uuid,
    limit: i64,
) -> Result<Vec<ThreadInboxEntry>, sqlx::Error> {
    // - root: every message that has at least one reply (joined via
    //   replies.thread_root_id or replies.reply_to_id for back-compat
    //   with pre-M2 inline replies).
    // - thread_read_state: optional join. NULL last_read_at means the
    //   caller never opened the thread, so every reply is unread.
    // - Visibility: caller must be a non-removed member of the parent's
    //   conversation.
    sqlx::query_as::<_, ThreadInboxEntry>(
        "WITH replies AS ( \
             SELECT \
                 COALESCE(m.thread_root_id, m.reply_to_id) AS root_id, \
                 m.created_at, \
                 m.content, \
                 m.sender_id \
             FROM messages m \
             WHERE (m.thread_root_id IS NOT NULL OR m.reply_to_id IS NOT NULL) \
               AND m.deleted_at IS NULL \
         ), latest AS ( \
             SELECT \
                 r.root_id, \
                 COUNT(*) AS reply_count, \
                 MAX(r.created_at) AS last_reply_at \
             FROM replies r \
             GROUP BY r.root_id \
         ), latest_msg AS ( \
             SELECT DISTINCT ON (r.root_id) \
                 r.root_id, \
                 LEFT(r.content, 120) AS last_reply_excerpt, \
                 r.sender_id AS last_reply_sender_id \
             FROM replies r \
             ORDER BY r.root_id, r.created_at DESC \
         ) \
         SELECT \
             root.id AS thread_root_id, \
             root.conversation_id, \
             root.channel_id, \
             ru.username AS parent_sender_username, \
             LEFT(root.content, 120) AS parent_excerpt, \
             latest.last_reply_at, \
             latest_msg.last_reply_excerpt, \
             lru.username AS last_reply_sender_username, \
             latest.reply_count, \
             COALESCE(( \
                 SELECT COUNT(*) FROM replies r2 \
                 WHERE r2.root_id = root.id \
                   AND r2.created_at > COALESCE(trs.last_read_at, 'epoch'::timestamptz) \
             ), latest.reply_count) AS unread_count \
         FROM latest \
         JOIN messages root ON root.id = latest.root_id AND root.deleted_at IS NULL \
         JOIN users ru ON ru.id = root.sender_id \
         JOIN latest_msg ON latest_msg.root_id = root.id \
         JOIN users lru ON lru.id = latest_msg.last_reply_sender_id \
         JOIN conversation_members cm \
              ON cm.conversation_id = root.conversation_id \
             AND cm.user_id = $1 \
             AND cm.is_removed = false \
         LEFT JOIN thread_read_state trs \
              ON trs.user_id = $1 AND trs.thread_root_id = root.id \
         ORDER BY latest.last_reply_at DESC \
         LIMIT $2",
    )
    .bind(user_id)
    .bind(limit)
    .fetch_all(pool)
    .await
}

/// Bump (or insert) the read marker so future inbox calls treat replies
/// newer than `at` as unread and earlier replies as read.
pub async fn mark_thread_read(
    pool: &sqlx::PgPool,
    user_id: Uuid,
    thread_root_id: Uuid,
    at: DateTime<Utc>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO thread_read_state (user_id, thread_root_id, last_read_at) \
         VALUES ($1, $2, $3) \
         ON CONFLICT (user_id, thread_root_id) \
         DO UPDATE SET last_read_at = GREATEST(thread_read_state.last_read_at, EXCLUDED.last_read_at)",
    )
    .bind(user_id)
    .bind(thread_root_id)
    .bind(at)
    .execute(pool)
    .await?;
    Ok(())
}

/// Count of distinct threads the user has unread replies in. Powers the
/// nav-rail badge.
pub async fn unread_thread_count(pool: &sqlx::PgPool, user_id: Uuid) -> Result<i64, sqlx::Error> {
    let row: (i64,) = sqlx::query_as(
        "SELECT COUNT(DISTINCT root_id) FROM ( \
             SELECT \
                 COALESCE(m.thread_root_id, m.reply_to_id) AS root_id, \
                 m.created_at, \
                 m.conversation_id \
             FROM messages m \
             WHERE (m.thread_root_id IS NOT NULL OR m.reply_to_id IS NOT NULL) \
               AND m.deleted_at IS NULL \
         ) r \
         JOIN conversation_members cm \
              ON cm.conversation_id = r.conversation_id \
             AND cm.user_id = $1 \
             AND cm.is_removed = false \
         LEFT JOIN thread_read_state trs \
              ON trs.user_id = $1 AND trs.thread_root_id = r.root_id \
         WHERE r.created_at > COALESCE(trs.last_read_at, 'epoch'::timestamptz)",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}
