//! Persistent canvas state queries for the voice-lounge canvas feature.
//!
//! Each voice channel has exactly one canvas row (created lazily on first
//! write).  Drawing strokes and images are stored as JSONB arrays so that the
//! board survives across leave/rejoin cycles.  Avatar positions are *not*
//! persisted here — they are broadcast via WebSocket and are ephemeral.

use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CanvasRow {
    pub channel_id: Uuid,
    pub drawing_data: serde_json::Value,
    pub images_data: serde_json::Value,
}

/// Return the canvas row for a channel, or a default empty state if none
/// exists yet.
pub async fn get(pool: &PgPool, channel_id: Uuid) -> Result<CanvasRow, sqlx::Error> {
    let row = sqlx::query_as::<_, CanvasRow>(
        "SELECT channel_id, drawing_data, images_data
         FROM channel_canvas
         WHERE channel_id = $1",
    )
    .bind(channel_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.unwrap_or(CanvasRow {
        channel_id,
        drawing_data: serde_json::Value::Array(vec![]),
        images_data: serde_json::Value::Array(vec![]),
    }))
}

/// Maximum number of strokes stored per canvas channel.
///
/// Each stroke object is a JSON value bounded by the 64 KB per-frame WS guard.
/// 2 000 strokes caps cumulative JSONB column growth at a predictable ceiling
/// without requiring periodic cleanup.
pub const MAX_STROKES: i64 = 2_000;

/// Maximum number of images stored per canvas channel.
pub const MAX_IMAGES: i64 = 2_000;

/// JSON key under which a stroke/image's authoring user id is persisted.
/// Used by [`clear_user_drawings`] to scope a `clear` to one member.
const AUTHOR_KEY: &str = "from_user_id";

/// Stamp the authoring user id into a stroke/image JSON object so a later
/// per-user clear can target it. No-op if the payload isn't a JSON object
/// (the validator already guarantees object shape for persisted kinds, but
/// we stay defensive rather than panic).
fn stamp_author(payload: &mut serde_json::Value, author_id: Uuid) {
    if let Some(map) = payload.as_object_mut() {
        map.insert(
            AUTHOR_KEY.to_string(),
            serde_json::Value::String(author_id.to_string()),
        );
    }
}

/// Append a drawing stroke to the channel canvas.
///
/// The stroke must be a JSON object with at least `{ "id": "...", ... }`.
/// Idempotent: if a stroke with the same `id` already exists it is ignored.
///
/// Returns `Err(sqlx::Error::RowNotFound)` when the canvas has reached
/// [`MAX_STROKES`] (reusing `RowNotFound` as a sentinel; callers convert
/// this to a user-facing error via [`CanvasCapError`]).
pub async fn append_stroke(
    pool: &PgPool,
    channel_id: Uuid,
    author_id: Uuid,
    mut stroke: serde_json::Value,
) -> Result<(), CanvasCapError> {
    // Stamp authorship so a later `scope: "mine"` clear can target only this
    // user's strokes. The receiving client's `CanvasStroke.fromJson` ignores
    // unknown keys, so the extra field is invisible to live participants.
    stamp_author(&mut stroke, author_id);
    // Serialize concurrent appends on this channel's canvas row so the cap is
    // enforced atomically: read the length under a row lock (`FOR UPDATE`) and
    // append in the SAME transaction. The previous count-then-insert was a
    // TOCTOU race — two appends near the cap could both pass the `< MAX_STROKES`
    // check and both insert, pushing the array past the cap.
    //
    // NOTE: `jsonb_array_length` returns SQL INT4 (i32), not INT8 — decoding
    // as `i64` was a latent bug that fired the moment a row actually existed
    // ("mismatched types INT8 vs INT4" → cap check returned `Db` → the write
    // was silently skipped, so every stroke after the first vanished for late
    // joiners, user report 2026-05-27). Decode as INT4, widen at the compare.
    let mut tx = pool.begin().await?;
    let current_len: Option<i32> = sqlx::query_scalar(
        "SELECT jsonb_array_length(drawing_data)
         FROM channel_canvas
         WHERE channel_id = $1
         FOR UPDATE",
    )
    .bind(channel_id)
    .fetch_optional(&mut *tx)
    .await?;

    if i64::from(current_len.unwrap_or(0)) >= MAX_STROKES {
        return Err(CanvasCapError::CapReached); // tx rolls back on drop
    }

    sqlx::query(
        "INSERT INTO channel_canvas (channel_id, drawing_data, images_data)
         VALUES ($1, jsonb_build_array($2::jsonb), '[]')
         ON CONFLICT (channel_id) DO UPDATE
         SET drawing_data = CASE
               WHEN EXISTS (
                 SELECT 1 FROM jsonb_array_elements(channel_canvas.drawing_data) s
                 WHERE s->>'id' = $2::jsonb->>'id'
               ) THEN channel_canvas.drawing_data
               ELSE channel_canvas.drawing_data || jsonb_build_array($2::jsonb)
             END,
             updated_at = now()",
    )
    .bind(channel_id)
    .bind(&stroke)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(())
}

/// Error type for canvas append operations that enforce a row-count cap.
#[derive(Debug)]
pub enum CanvasCapError {
    /// The canvas has reached the maximum allowed number of entries.
    CapReached,
    /// An underlying database error occurred.
    Db(sqlx::Error),
}

impl std::fmt::Display for CanvasCapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CanvasCapError::CapReached => write!(f, "canvas row-count cap reached"),
            CanvasCapError::Db(e) => write!(f, "database error: {e}"),
        }
    }
}

impl From<sqlx::Error> for CanvasCapError {
    fn from(e: sqlx::Error) -> Self {
        CanvasCapError::Db(e)
    }
}

/// Erase all drawing strokes for a channel, keeping images intact.
pub async fn clear_drawing(pool: &PgPool, channel_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO channel_canvas (channel_id, drawing_data, images_data)
         VALUES ($1, '[]', '[]')
         ON CONFLICT (channel_id) DO UPDATE
         SET drawing_data = '[]',
             updated_at   = now()",
    )
    .bind(channel_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// Erase only the strokes and images authored by `user_id`, leaving every
/// other member's drawings intact.
///
/// Authorship is stamped into each persisted stroke/image object under the
/// `from_user_id` key at write time (see [`append_stroke`] / [`add_image`]).
/// Entries written before authorship stamping landed have no `from_user_id`
/// and are therefore treated as un-owned: a `scope: "mine"` clear leaves them
/// in place rather than wiping another member's history on a guess.
pub async fn clear_user_drawings(
    pool: &PgPool,
    channel_id: Uuid,
    user_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE channel_canvas
         SET drawing_data = (
               SELECT COALESCE(jsonb_agg(s), '[]'::jsonb)
               FROM jsonb_array_elements(drawing_data) s
               WHERE s->>'from_user_id' IS DISTINCT FROM $2
             ),
             images_data = (
               SELECT COALESCE(jsonb_agg(img), '[]'::jsonb)
               FROM jsonb_array_elements(images_data) img
               WHERE img->>'from_user_id' IS DISTINCT FROM $2
             ),
             updated_at = now()
         WHERE channel_id = $1",
    )
    .bind(channel_id)
    .bind(user_id.to_string())
    .execute(pool)
    .await?;

    Ok(())
}

/// Erase all canvas data for a channel (drawings and images).
pub async fn clear_all(pool: &PgPool, channel_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO channel_canvas (channel_id, drawing_data, images_data)
         VALUES ($1, '[]', '[]')
         ON CONFLICT (channel_id) DO UPDATE
         SET drawing_data = '[]',
             images_data  = '[]',
             updated_at   = now()",
    )
    .bind(channel_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// Add an image to the canvas (appends; duplicates are filtered by `id`).
///
/// Returns [`CanvasCapError::CapReached`] when the images array has reached
/// [`MAX_IMAGES`].
pub async fn add_image(
    pool: &PgPool,
    channel_id: Uuid,
    author_id: Uuid,
    mut image: serde_json::Value,
) -> Result<(), CanvasCapError> {
    // Stamp authorship so a later `scope: "mine"` clear can target only this
    // user's images. `CanvasImage.fromJson` ignores the extra key.
    stamp_author(&mut image, author_id);
    // Same atomic cap enforcement as `append_stroke`: read the image count
    // under a row lock and append in one transaction so two concurrent adds
    // near the cap can't both pass the check and overshoot MAX_IMAGES. See
    // `append_stroke` for the i64-vs-i32 cap-decode bug context — same root
    // cause was wiping every image past the first.
    let mut tx = pool.begin().await?;
    let current_len: Option<i32> = sqlx::query_scalar(
        "SELECT jsonb_array_length(images_data)
         FROM channel_canvas
         WHERE channel_id = $1
         FOR UPDATE",
    )
    .bind(channel_id)
    .fetch_optional(&mut *tx)
    .await?;

    if i64::from(current_len.unwrap_or(0)) >= MAX_IMAGES {
        return Err(CanvasCapError::CapReached); // tx rolls back on drop
    }

    sqlx::query(
        "INSERT INTO channel_canvas (channel_id, drawing_data, images_data)
         VALUES ($1, '[]', jsonb_build_array($2::jsonb))
         ON CONFLICT (channel_id) DO UPDATE
         SET images_data = CASE
               WHEN EXISTS (
                 SELECT 1 FROM jsonb_array_elements(channel_canvas.images_data) img
                 WHERE img->>'id' = $2::jsonb->>'id'
               ) THEN channel_canvas.images_data
               ELSE channel_canvas.images_data || jsonb_build_array($2::jsonb)
             END,
             updated_at = now()",
    )
    .bind(channel_id)
    .bind(&image)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(())
}

/// Update the position / size of an existing image in-place.
///
/// Replaces the image object whose `id` matches that of `updated`; if no
/// matching image is found the array is left unchanged.
pub async fn update_image(
    pool: &PgPool,
    channel_id: Uuid,
    updated: serde_json::Value,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE channel_canvas
         SET images_data = COALESCE((
           SELECT jsonb_agg(
             CASE WHEN img->>'id' = $2::jsonb->>'id' THEN $2::jsonb ELSE img END
           )
           FROM jsonb_array_elements(images_data) img
         ), '[]'::jsonb),
         updated_at = now()
         WHERE channel_id = $1",
    )
    .bind(channel_id)
    .bind(&updated)
    .execute(pool)
    .await?;

    Ok(())
}

/// Remove an image by id.
pub async fn remove_image(
    pool: &PgPool,
    channel_id: Uuid,
    image_id: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE channel_canvas
         SET images_data = (
           SELECT COALESCE(jsonb_agg(img), '[]'::jsonb)
           FROM jsonb_array_elements(images_data) img
           WHERE img->>'id' != $2
         ),
         updated_at = now()
         WHERE channel_id = $1",
    )
    .bind(channel_id)
    .bind(image_id)
    .execute(pool)
    .await?;

    Ok(())
}
