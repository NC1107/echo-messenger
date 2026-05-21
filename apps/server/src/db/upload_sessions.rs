//! Upload-session queries for the chunked / resumable upload pipeline (#556).
//!
//! Each row represents one in-flight chunked upload.  The handler in
//! `routes/media.rs` creates rows in `init`, updates `bytes_received` after
//! every chunk write, and either flips the row to `finalized` (with the
//! corresponding `media` row created in the same transaction) or leaves it
//! `pending` for the cleanup sweep to reap after 24 h of inactivity.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

pub const STATUS_PENDING: &str = "pending";
pub const STATUS_FINALIZED: &str = "finalized";
pub const STATUS_ABORTED: &str = "aborted";

#[derive(Debug, sqlx::FromRow)]
pub struct UploadSessionRow {
    pub id: Uuid,
    pub user_id: Uuid,
    pub filename: String,
    pub mime_type: String,
    pub total_size: i64,
    pub bytes_received: i64,
    pub conversation_id: Option<Uuid>,
    pub temp_path: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Insert a new pending upload session.  The caller has already validated
/// `total_size` and minted the UUID-only `temp_path` -- this function just
/// records the row so subsequent chunk PATCHes can locate it.
#[allow(clippy::too_many_arguments)]
pub async fn create(
    pool: &PgPool,
    id: Uuid,
    user_id: Uuid,
    filename: &str,
    mime_type: &str,
    total_size: i64,
    conversation_id: Option<Uuid>,
    temp_path: &str,
) -> Result<UploadSessionRow, sqlx::Error> {
    sqlx::query_as::<_, UploadSessionRow>(
        "INSERT INTO upload_sessions \
            (id, user_id, filename, mime_type, total_size, conversation_id, temp_path, status) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending') \
         RETURNING id, user_id, filename, mime_type, total_size, bytes_received, \
                   conversation_id, temp_path, status, created_at, updated_at",
    )
    .bind(id)
    .bind(user_id)
    .bind(filename)
    .bind(mime_type)
    .bind(total_size)
    .bind(conversation_id)
    .bind(temp_path)
    .fetch_one(pool)
    .await
}

/// Fetch one session.  Returns `None` when no row exists -- callers map that
/// to 404.  Always filter by `user_id` at the call site so one user cannot
/// poke at another user's upload by ID.
pub async fn get(
    pool: &PgPool,
    id: Uuid,
    user_id: Uuid,
) -> Result<Option<UploadSessionRow>, sqlx::Error> {
    sqlx::query_as::<_, UploadSessionRow>(
        "SELECT id, user_id, filename, mime_type, total_size, bytes_received, \
                conversation_id, temp_path, status, created_at, updated_at \
         FROM upload_sessions WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

/// Add `delta` bytes to the running `bytes_received` counter.  Called once
/// per chunk **after** the bytes have already been flushed to disk so a
/// crash between disk write and DB update reports too few bytes (the client
/// will resume from `bytes_received` and re-send the trailing chunk), never
/// too many.
pub async fn add_bytes(
    pool: &PgPool,
    id: Uuid,
    delta: i64,
) -> Result<UploadSessionRow, sqlx::Error> {
    sqlx::query_as::<_, UploadSessionRow>(
        "UPDATE upload_sessions \
         SET bytes_received = bytes_received + $2, updated_at = now() \
         WHERE id = $1 \
         RETURNING id, user_id, filename, mime_type, total_size, bytes_received, \
                   conversation_id, temp_path, status, created_at, updated_at",
    )
    .bind(id)
    .bind(delta)
    .fetch_one(pool)
    .await
}

/// Mark a session as `finalized`.  Called from the finalize handler after
/// the temp file has been renamed and the `media` row inserted.
pub async fn mark_finalized(pool: &PgPool, id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE upload_sessions SET status = 'finalized', updated_at = now() WHERE id = $1",
    )
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Mark a session as `aborted`.  Called by the cleanup sweep and (in
/// future) an explicit cancel endpoint.  Returns the row before update so
/// the sweep can locate `temp_path` for unlinking.
pub async fn mark_aborted(pool: &PgPool, id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE upload_sessions SET status = 'aborted', updated_at = now() WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Return every pending session that has been idle longer than
/// `idle_seconds`.  The cleanup task feeds these into [`mark_aborted`] and
/// unlinks each `temp_path`.
pub async fn list_stale_pending(
    pool: &PgPool,
    idle_seconds: i64,
) -> Result<Vec<UploadSessionRow>, sqlx::Error> {
    sqlx::query_as::<_, UploadSessionRow>(
        "SELECT id, user_id, filename, mime_type, total_size, bytes_received, \
                conversation_id, temp_path, status, created_at, updated_at \
         FROM upload_sessions \
         WHERE status = 'pending' AND updated_at < now() - make_interval(secs => $1)",
    )
    .bind(idle_seconds)
    .fetch_all(pool)
    .await
}
