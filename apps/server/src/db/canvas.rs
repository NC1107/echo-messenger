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

/// Append a drawing stroke to the channel canvas.
///
/// The stroke must be a JSON object with at least `{ "id": "...", ... }`.
/// Idempotent: if a stroke with the same `id` already exists it is ignored.
pub async fn append_stroke(
    pool: &PgPool,
    channel_id: Uuid,
    stroke: serde_json::Value,
) -> Result<(), sqlx::Error> {
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
pub async fn add_image(
    pool: &PgPool,
    channel_id: Uuid,
    image: serde_json::Value,
) -> Result<(), sqlx::Error> {
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
