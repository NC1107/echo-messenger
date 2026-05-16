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
    stroke: serde_json::Value,
) -> Result<(), CanvasCapError> {
    // Check current stroke count before appending to bound cumulative growth.
    let current_len: Option<i64> = sqlx::query_scalar(
        "SELECT jsonb_array_length(drawing_data)
         FROM channel_canvas
         WHERE channel_id = $1",
    )
    .bind(channel_id)
    .fetch_optional(pool)
    .await?;

    if current_len.unwrap_or(0) >= MAX_STROKES {
        return Err(CanvasCapError::CapReached);
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
    .execute(pool)
    .await?;

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
    image: serde_json::Value,
) -> Result<(), CanvasCapError> {
    // Check current image count before appending to bound cumulative growth.
    let current_len: Option<i64> = sqlx::query_scalar(
        "SELECT jsonb_array_length(images_data)
         FROM channel_canvas
         WHERE channel_id = $1",
    )
    .bind(channel_id)
    .fetch_optional(pool)
    .await?;

    if current_len.unwrap_or(0) >= MAX_IMAGES {
        return Err(CanvasCapError::CapReached);
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
    .execute(pool)
    .await?;

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
