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
    pub conversation_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
}

pub async fn create_media(
    pool: &PgPool,
    id: Uuid,
    uploader_id: Uuid,
    filename: &str,
    mime_type: &str,
    size_bytes: i64,
    conversation_id: Option<Uuid>,
) -> Result<MediaRow, sqlx::Error> {
    sqlx::query_as::<_, MediaRow>(
        "INSERT INTO media (id, uploader_id, filename, mime_type, size_bytes, conversation_id) \
         VALUES ($1, $2, $3, $4, $5, $6) \
         RETURNING id, uploader_id, filename, mime_type, size_bytes, conversation_id, created_at",
    )
    .bind(id)
    .bind(uploader_id)
    .bind(filename)
    .bind(mime_type)
    .bind(size_bytes)
    .bind(conversation_id)
    .fetch_one(pool)
    .await
}

pub async fn get_media(pool: &PgPool, id: Uuid) -> Result<Option<MediaRow>, sqlx::Error> {
    sqlx::query_as::<_, MediaRow>(
        "SELECT id, uploader_id, filename, mime_type, size_bytes, conversation_id, created_at \
         FROM media WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

/// Check whether a user can access a media file.
///
/// Access is granted when:
///   1. The user uploaded the file (uploader_id), OR
///   2. The media has a conversation_id and the user is a member of that conversation, OR
///   3. The media ID appears in a message content within a conversation the user belongs to.
pub async fn can_user_access_media(
    pool: &PgPool,
    media_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let row = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(
            SELECT 1 FROM media WHERE id = $1 AND uploader_id = $2
            UNION ALL
            SELECT 1 FROM media m
              JOIN conversation_members cm ON cm.conversation_id = m.conversation_id
              WHERE m.id = $1 AND cm.user_id = $2
            UNION ALL
            SELECT 1 FROM messages msg
              JOIN conversation_members cm ON cm.conversation_id = msg.conversation_id
              WHERE msg.content LIKE '%' || $1::text || '%'
                AND cm.user_id = $2
        )",
    )
    .bind(media_id)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    Ok(row)
}
