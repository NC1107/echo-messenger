//! Media metadata database queries.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct MediaRow {
    pub id: Uuid,
    pub uploader_id: Uuid,
    pub filename: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub created_at: DateTime<Utc>,
}

pub async fn create_media(
    pool: &PgPool,
    uploader_id: Uuid,
    filename: &str,
    mime_type: &str,
    size_bytes: i64,
) -> Result<MediaRow, sqlx::Error> {
    sqlx::query_as::<_, MediaRow>(
        "INSERT INTO media (uploader_id, filename, mime_type, size_bytes) \
         VALUES ($1, $2, $3, $4) \
         RETURNING id, uploader_id, filename, mime_type, size_bytes, created_at",
    )
    .bind(uploader_id)
    .bind(filename)
    .bind(mime_type)
    .bind(size_bytes)
    .fetch_one(pool)
    .await
}

pub async fn get_media(pool: &PgPool, id: Uuid) -> Result<Option<MediaRow>, sqlx::Error> {
    sqlx::query_as::<_, MediaRow>(
        "SELECT id, uploader_id, filename, mime_type, size_bytes, created_at \
         FROM media WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}
