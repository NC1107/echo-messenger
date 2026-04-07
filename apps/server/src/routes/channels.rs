//! Group channel and voice session REST endpoints.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;
use crate::types::{ConversationKind, Role};

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateChannelRequest {
    pub name: String,
    pub kind: String,
    pub topic: Option<String>,
    pub position: Option<i32>,
    pub category: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateChannelRequest {
    pub name: Option<String>,
    pub topic: Option<String>,
    pub position: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateVoiceStateRequest {
    pub is_muted: bool,
    pub is_deafened: bool,
    pub push_to_talk: bool,
}

#[derive(Debug, Serialize)]
pub struct ChannelResponse {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub name: String,
    pub kind: String,
    pub topic: Option<String>,
    pub position: i32,
    pub category: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Serialize)]
pub struct VoiceSessionResponse {
    pub channel_id: Uuid,
    pub user_id: Uuid,
    pub username: String,
    pub avatar_url: Option<String>,
    pub is_muted: bool,
    pub is_deafened: bool,
    pub push_to_talk: bool,
    pub joined_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

fn is_valid_channel_kind(kind: &str) -> bool {
    matches!(kind, "text" | "voice")
}

fn normalize_channel_name(name: &str) -> String {
    name.trim().to_lowercase().replace(' ', "-")
}

async fn ensure_group_member(
    state: &AppState,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<(), AppError> {
    let kind = db::groups::get_conversation_kind(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ensure_group_member/get_kind: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("Group not found"))?;

    if ConversationKind::from_str_opt(&kind) != Some(ConversationKind::Group) {
        return Err(AppError::bad_request("Conversation is not a group"));
    }

    let is_member = db::groups::is_member(&state.pool, group_id, user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ensure_group_member/is_member: {e:?}");
            AppError::internal("Database error")
        })?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    Ok(())
}

/// Verify that the user is an owner or admin of the group.
async fn ensure_group_admin(
    state: &AppState,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<(), AppError> {
    let role = db::groups::get_member_role(&state.pool, group_id, user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ensure_group_admin/get_role: {e:?}");
            AppError::internal("Database error")
        })?;
    match role.as_deref().and_then(Role::from_str_opt) {
        Some(r) if r.is_admin_or_above() => Ok(()),
        _ => Err(AppError::unauthorized(
            "Only group owners and admins can manage channels",
        )),
    }
}

async fn ensure_channel_in_group(
    state: &AppState,
    group_id: Uuid,
    channel_id: Uuid,
) -> Result<db::channels::ChannelRow, AppError> {
    let channel = db::channels::get_channel(&state.pool, channel_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ensure_channel_in_group/get_channel: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("Channel not found"))?;

    if channel.conversation_id != group_id {
        return Err(AppError::bad_request("Channel is not part of this group"));
    }

    Ok(channel)
}

async fn broadcast_to_group(state: &AppState, group_id: Uuid, event: &serde_json::Value) {
    let member_ids = match db::groups::get_conversation_member_ids(&state.pool, group_id).await {
        Ok(ids) => ids,
        Err(_) => return,
    };

    if let Ok(json) = serde_json::to_string(event) {
        state.hub.broadcast_json(&member_ids, &json, None);
    }
}

/// GET /api/groups/:id/channels
pub async fn list_channels(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;

    let rows = db::channels::list_channels(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in list_channels: {e:?}");
            AppError::internal("Database error")
        })?;

    let channels: Vec<ChannelResponse> = rows
        .into_iter()
        .map(|row| ChannelResponse {
            id: row.id,
            conversation_id: row.conversation_id,
            name: row.name,
            kind: row.kind,
            topic: row.topic,
            position: row.position,
            category: row.category,
            created_at: row.created_at,
        })
        .collect();

    Ok(Json(channels))
}

/// POST /api/groups/:id/channels
pub async fn create_channel(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    Json(body): Json<CreateChannelRequest>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;
    ensure_group_admin(&state, group_id, auth.user_id).await?;

    let kind = body.kind.trim().to_lowercase();
    if !is_valid_channel_kind(&kind) {
        return Err(AppError::bad_request(
            "Channel kind must be 'text' or 'voice'",
        ));
    }

    let normalized_name = normalize_channel_name(&body.name);
    if normalized_name.is_empty() || normalized_name.len() > 80 {
        return Err(AppError::bad_request(
            "Channel name must be between 1 and 80 characters",
        ));
    }

    let position = match body.position {
        Some(value) if value >= 0 => value,
        Some(_) => return Err(AppError::bad_request("Position must be non-negative")),
        None => db::channels::next_channel_position(&state.pool, group_id, &kind)
            .await
            .map_err(|e| {
                tracing::error!("DB error in create_channel/next_position: {e:?}");
                AppError::internal("Database error")
            })?,
    };

    let created = db::channels::create_channel(
        &state.pool,
        group_id,
        &normalized_name,
        &kind,
        body.topic.as_deref(),
        position,
        body.category.as_deref(),
    )
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(ref db_err) if db_err.code().as_deref() == Some("23505") => {
            AppError::conflict("A channel with this name already exists")
        }
        _ => AppError::internal("Failed to create channel"),
    })?;

    let response = ChannelResponse {
        id: created.id,
        conversation_id: created.conversation_id,
        name: created.name,
        kind: created.kind,
        topic: created.topic,
        position: created.position,
        category: created.category,
        created_at: created.created_at,
    };

    broadcast_to_group(
        &state,
        group_id,
        &serde_json::json!({
            "type": "channel_created",
            "group_id": group_id,
            "channel": response,
        }),
    )
    .await;

    Ok((StatusCode::CREATED, Json(response)))
}

/// PUT /api/groups/:id/channels/:channel_id
pub async fn update_channel(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
    Json(body): Json<UpdateChannelRequest>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;
    ensure_group_admin(&state, group_id, auth.user_id).await?;
    let channel = ensure_channel_in_group(&state, group_id, channel_id).await?;

    let name = body
        .name
        .as_ref()
        .map(|s| normalize_channel_name(s))
        .filter(|s| !s.is_empty());

    if body.name.is_some() && name.is_none() {
        return Err(AppError::bad_request("Channel name cannot be empty"));
    }

    let updated = db::channels::update_channel(
        &state.pool,
        channel.id,
        name.as_deref(),
        body.topic.as_deref(),
        body.position,
    )
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(ref db_err) if db_err.code().as_deref() == Some("23505") => {
            AppError::conflict("A channel with this name already exists")
        }
        _ => AppError::internal("Failed to update channel"),
    })?
    .ok_or_else(|| AppError::bad_request("Channel not found"))?;

    let response = ChannelResponse {
        id: updated.id,
        conversation_id: updated.conversation_id,
        name: updated.name,
        kind: updated.kind,
        topic: updated.topic,
        position: updated.position,
        category: updated.category,
        created_at: updated.created_at,
    };

    broadcast_to_group(
        &state,
        group_id,
        &serde_json::json!({
            "type": "channel_updated",
            "group_id": group_id,
            "channel": response,
        }),
    )
    .await;

    Ok(Json(response))
}

/// DELETE /api/groups/:id/channels/:channel_id
pub async fn delete_channel(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;
    ensure_group_admin(&state, group_id, auth.user_id).await?;
    let channel = ensure_channel_in_group(&state, group_id, channel_id).await?;

    let deleted = db::channels::soft_delete_channel(&state.pool, channel.id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in delete_channel: {e:?}");
            AppError::internal("Failed to delete channel")
        })?;

    if !deleted {
        return Err(AppError::bad_request("Channel not found"));
    }

    broadcast_to_group(
        &state,
        group_id,
        &serde_json::json!({
            "type": "channel_deleted",
            "group_id": group_id,
            "channel_id": channel.id,
        }),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

/// GET /api/groups/:id/channels/:channel_id/voice
pub async fn list_voice_sessions(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;
    let channel = ensure_channel_in_group(&state, group_id, channel_id).await?;

    if channel.kind != "voice" {
        return Err(AppError::bad_request("Channel is not a voice channel"));
    }

    let rows = db::channels::list_voice_sessions(&state.pool, channel.id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in list_voice_sessions: {e:?}");
            AppError::internal("Database error")
        })?;

    let sessions: Vec<VoiceSessionResponse> = rows
        .into_iter()
        .map(|row| VoiceSessionResponse {
            channel_id: row.channel_id,
            user_id: row.user_id,
            username: row.username,
            avatar_url: row.avatar_url,
            is_muted: row.is_muted,
            is_deafened: row.is_deafened,
            push_to_talk: row.push_to_talk,
            joined_at: row.joined_at,
            updated_at: row.updated_at,
        })
        .collect();

    Ok(Json(sessions))
}

/// POST /api/groups/:id/channels/:channel_id/voice/join
pub async fn join_voice_channel(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;
    let channel = ensure_channel_in_group(&state, group_id, channel_id).await?;

    if channel.kind != "voice" {
        return Err(AppError::bad_request("Channel is not a voice channel"));
    }

    let (removed_channel_ids, joined) =
        db::channels::leave_and_join_voice_channel(&state.pool, group_id, channel.id, auth.user_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in join_voice_channel: {e:?}");
                AppError::internal("Failed to join voice channel")
            })?;

    for old_channel_id in removed_channel_ids {
        if old_channel_id == channel.id {
            continue;
        }
        broadcast_to_group(
            &state,
            group_id,
            &serde_json::json!({
                "type": "voice_session_left",
                "group_id": group_id,
                "channel_id": old_channel_id,
                "user_id": auth.user_id,
            }),
        )
        .await;
    }

    broadcast_to_group(
        &state,
        group_id,
        &serde_json::json!({
            "type": "voice_session_joined",
            "group_id": group_id,
            "channel_id": joined.channel_id,
            "user_id": joined.user_id,
            "is_muted": joined.is_muted,
            "is_deafened": joined.is_deafened,
            "push_to_talk": joined.push_to_talk,
        }),
    )
    .await;

    Ok(Json(serde_json::json!({ "status": "joined" })))
}

/// POST /api/groups/:id/channels/:channel_id/voice/leave
pub async fn leave_voice_channel(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;
    let channel = ensure_channel_in_group(&state, group_id, channel_id).await?;

    if channel.kind != "voice" {
        return Err(AppError::bad_request("Channel is not a voice channel"));
    }

    let removed = db::channels::leave_voice_channel(&state.pool, channel.id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in leave_voice_channel: {e:?}");
            AppError::internal("Failed to leave voice channel")
        })?;

    if !removed {
        return Ok(Json(serde_json::json!({ "status": "already_left" })));
    }

    broadcast_to_group(
        &state,
        group_id,
        &serde_json::json!({
            "type": "voice_session_left",
            "group_id": group_id,
            "channel_id": channel.id,
            "user_id": auth.user_id,
        }),
    )
    .await;

    Ok(Json(serde_json::json!({ "status": "left" })))
}

/// PUT /api/groups/:id/channels/:channel_id/voice/state
pub async fn update_voice_state(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
    Json(body): Json<UpdateVoiceStateRequest>,
) -> Result<impl IntoResponse, AppError> {
    ensure_group_member(&state, group_id, auth.user_id).await?;
    let channel = ensure_channel_in_group(&state, group_id, channel_id).await?;

    if channel.kind != "voice" {
        return Err(AppError::bad_request("Channel is not a voice channel"));
    }

    let updated = db::channels::update_voice_state(
        &state.pool,
        channel.id,
        auth.user_id,
        body.is_muted,
        body.is_deafened,
        body.push_to_talk,
    )
    .await
    .map_err(|e| {
        tracing::error!("DB error in update_voice_state: {e:?}");
        AppError::internal("Failed to update voice state")
    })?
    .ok_or_else(|| AppError::bad_request("Voice session not found"))?;

    broadcast_to_group(
        &state,
        group_id,
        &serde_json::json!({
            "type": "voice_session_updated",
            "group_id": group_id,
            "channel_id": updated.channel_id,
            "user_id": updated.user_id,
            "is_muted": updated.is_muted,
            "is_deafened": updated.is_deafened,
            "push_to_talk": updated.push_to_talk,
            "updated_at": updated.updated_at,
        }),
    )
    .await;

    Ok(Json(serde_json::json!({ "status": "updated" })))
}
