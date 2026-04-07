//! Channel and voice session database queries.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct ChannelRow {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub name: String,
    pub kind: String,
    pub topic: Option<String>,
    pub position: i32,
    pub category: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct VoiceSessionRow {
    pub channel_id: Uuid,
    pub user_id: Uuid,
    pub is_muted: bool,
    pub is_deafened: bool,
    pub push_to_talk: bool,
    pub joined_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct VoiceSessionWithUserRow {
    pub channel_id: Uuid,
    pub user_id: Uuid,
    pub username: String,
    pub avatar_url: Option<String>,
    pub is_muted: bool,
    pub is_deafened: bool,
    pub push_to_talk: bool,
    pub joined_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub async fn list_channels(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Vec<ChannelRow>, sqlx::Error> {
    sqlx::query_as::<_, ChannelRow>(
        "SELECT id, conversation_id, name, kind, topic, position, category, created_at
         FROM channels
         WHERE conversation_id = $1 AND deleted_at IS NULL
         ORDER BY kind ASC, position ASC, created_at ASC",
    )
    .bind(conversation_id)
    .fetch_all(pool)
    .await
}

pub async fn get_channel(
    pool: &PgPool,
    channel_id: Uuid,
) -> Result<Option<ChannelRow>, sqlx::Error> {
    sqlx::query_as::<_, ChannelRow>(
        "SELECT id, conversation_id, name, kind, topic, position, category, created_at
         FROM channels
         WHERE id = $1 AND deleted_at IS NULL",
    )
    .bind(channel_id)
    .fetch_optional(pool)
    .await
}

pub async fn get_default_text_channel(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Option<ChannelRow>, sqlx::Error> {
    sqlx::query_as::<_, ChannelRow>(
        "SELECT id, conversation_id, name, kind, topic, position, category, created_at
         FROM channels
         WHERE conversation_id = $1 AND kind = 'text' AND deleted_at IS NULL
         ORDER BY position ASC, created_at ASC
         LIMIT 1",
    )
    .bind(conversation_id)
    .fetch_optional(pool)
    .await
}

pub async fn create_channel(
    pool: &PgPool,
    conversation_id: Uuid,
    name: &str,
    kind: &str,
    topic: Option<&str>,
    position: i32,
    category: Option<&str>,
) -> Result<ChannelRow, sqlx::Error> {
    let default_category = if kind == "voice" {
        "Voice Channels"
    } else {
        "Text Channels"
    };
    let cat = category.unwrap_or(default_category);

    sqlx::query_as::<_, ChannelRow>(
        "INSERT INTO channels (conversation_id, name, kind, topic, position, category)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, conversation_id, name, kind, topic, position, category, created_at",
    )
    .bind(conversation_id)
    .bind(name)
    .bind(kind)
    .bind(topic)
    .bind(position)
    .bind(cat)
    .fetch_one(pool)
    .await
}

pub async fn next_channel_position(
    pool: &PgPool,
    conversation_id: Uuid,
    kind: &str,
) -> Result<i32, sqlx::Error> {
    let row: (Option<i32>,) = sqlx::query_as(
        "SELECT MAX(position) FROM channels
         WHERE conversation_id = $1 AND kind = $2 AND deleted_at IS NULL",
    )
    .bind(conversation_id)
    .bind(kind)
    .fetch_one(pool)
    .await?;

    Ok(row.0.unwrap_or(-1) + 1)
}

pub async fn update_channel(
    pool: &PgPool,
    channel_id: Uuid,
    name: Option<&str>,
    topic: Option<&str>,
    position: Option<i32>,
) -> Result<Option<ChannelRow>, sqlx::Error> {
    sqlx::query_as::<_, ChannelRow>(
        "UPDATE channels
         SET name = COALESCE($2, name),
             topic = CASE WHEN $3::text IS NULL THEN topic ELSE $3 END,
             position = COALESCE($4, position)
         WHERE id = $1 AND deleted_at IS NULL
         RETURNING id, conversation_id, name, kind, topic, position, category, created_at",
    )
    .bind(channel_id)
    .bind(name)
    .bind(topic)
    .bind(position)
    .fetch_optional(pool)
    .await
}

pub async fn soft_delete_channel(pool: &PgPool, channel_id: Uuid) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
        "UPDATE channels
         SET deleted_at = now()
         WHERE id = $1 AND deleted_at IS NULL",
    )
    .bind(channel_id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() > 0)
}

pub async fn leave_voice_channel(
    pool: &PgPool,
    channel_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let result = sqlx::query(
        "DELETE FROM voice_sessions
         WHERE channel_id = $1 AND user_id = $2",
    )
    .bind(channel_id)
    .bind(user_id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() > 0)
}

pub async fn update_voice_state(
    pool: &PgPool,
    channel_id: Uuid,
    user_id: Uuid,
    is_muted: bool,
    is_deafened: bool,
    push_to_talk: bool,
) -> Result<Option<VoiceSessionRow>, sqlx::Error> {
    sqlx::query_as::<_, VoiceSessionRow>(
        "UPDATE voice_sessions
         SET is_muted = $3,
             is_deafened = $4,
             push_to_talk = $5,
             updated_at = now()
         WHERE channel_id = $1 AND user_id = $2
         RETURNING channel_id, user_id, is_muted, is_deafened, push_to_talk, joined_at, updated_at",
    )
    .bind(channel_id)
    .bind(user_id)
    .bind(is_muted)
    .bind(is_deafened)
    .bind(push_to_talk)
    .fetch_optional(pool)
    .await
}

pub async fn list_voice_sessions(
    pool: &PgPool,
    channel_id: Uuid,
) -> Result<Vec<VoiceSessionWithUserRow>, sqlx::Error> {
    sqlx::query_as::<_, VoiceSessionWithUserRow>(
        "SELECT vs.channel_id, vs.user_id, u.username, u.avatar_url,
                vs.is_muted, vs.is_deafened, vs.push_to_talk, vs.joined_at, vs.updated_at
         FROM voice_sessions vs
         JOIN users u ON u.id = vs.user_id
         WHERE vs.channel_id = $1
         ORDER BY vs.joined_at ASC",
    )
    .bind(channel_id)
    .fetch_all(pool)
    .await
}

pub async fn is_user_in_voice_channel(
    pool: &PgPool,
    channel_id: Uuid,
    user_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS(
            SELECT 1 FROM voice_sessions
            WHERE channel_id = $1 AND user_id = $2
        )",
    )
    .bind(channel_id)
    .bind(user_id)
    .fetch_one(pool)
    .await?;

    Ok(row.0)
}

/// Remove all voice sessions for a user (called on WS disconnect to clean up
/// stale sessions from crashed clients). Returns (channel_id, conversation_id)
/// pairs so the caller can broadcast leave events.
pub async fn leave_all_user_voice_sessions(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Vec<(Uuid, Uuid)>, sqlx::Error> {
    let rows: Vec<(Uuid, Uuid)> = sqlx::query_as(
        "DELETE FROM voice_sessions vs
         USING channels c
         WHERE vs.channel_id = c.id
           AND vs.user_id = $1
         RETURNING c.id, c.conversation_id",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Delete voice sessions that have not been updated within `max_age_seconds`.
/// Returns (channel_id, conversation_id, user_id) tuples for each removed
/// session so the caller can broadcast leave events.
pub async fn cleanup_stale_voice_sessions(
    pool: &PgPool,
    max_age_seconds: i64,
) -> Result<Vec<(Uuid, Uuid, Uuid)>, sqlx::Error> {
    let rows: Vec<(Uuid, Uuid, Uuid)> = sqlx::query_as(
        "DELETE FROM voice_sessions vs \
         USING channels c \
         WHERE vs.channel_id = c.id \
           AND vs.updated_at < now() - make_interval(secs => $1::double precision) \
         RETURNING c.id, c.conversation_id, vs.user_id",
    )
    .bind(max_age_seconds as f64)
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Atomically leave all voice sessions in a conversation and join a new
/// channel. Wraps the leave + join in a single transaction to prevent race
/// conditions where a user briefly appears in zero or two channels.
pub async fn leave_and_join_voice_channel(
    pool: &PgPool,
    conversation_id: Uuid,
    channel_id: Uuid,
    user_id: Uuid,
) -> Result<(Vec<Uuid>, VoiceSessionRow), sqlx::Error> {
    let mut tx = pool.begin().await?;

    let removed: Vec<(Uuid,)> = sqlx::query_as(
        "DELETE FROM voice_sessions vs
         USING channels c
         WHERE vs.channel_id = c.id
           AND c.conversation_id = $1
           AND vs.user_id = $2
         RETURNING c.id",
    )
    .bind(conversation_id)
    .bind(user_id)
    .fetch_all(&mut *tx)
    .await?;

    let removed_ids: Vec<Uuid> = removed.into_iter().map(|(id,)| id).collect();

    let joined = sqlx::query_as::<_, VoiceSessionRow>(
        "INSERT INTO voice_sessions (channel_id, user_id)
         VALUES ($1, $2)
         ON CONFLICT (channel_id, user_id)
         DO UPDATE SET updated_at = now()
         RETURNING channel_id, user_id, is_muted, is_deafened, \
         push_to_talk, joined_at, updated_at",
    )
    .bind(channel_id)
    .bind(user_id)
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;

    Ok((removed_ids, joined))
}
