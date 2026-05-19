//! Group creation and retrieval endpoints.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};

use super::super::AppState;
use super::types::{CreateGroupRequest, GroupMemberResponse, GroupResponse};

/// POST /api/groups -- Create a new group conversation.
pub async fn create_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<CreateGroupRequest>,
) -> Result<impl IntoResponse, AppError> {
    if body.name.is_empty() || body.name.len() > 100 {
        return Err(AppError::bad_request(
            "Group name must be between 1 and 100 characters",
        ));
    }

    // Prevent duplicate public group names per creator
    if body.is_public {
        let already_exists =
            db::groups::user_has_public_group_named(&state.pool, auth.user_id, &body.name)
                .await
                .db_ctx("create_group/check_dup_name")?;
        if already_exists {
            return Err(AppError::conflict(
                "You already own a public group with this name",
            ));
        }
    }

    let group = db::groups::create_group_with_visibility(
        &state.pool,
        auth.user_id,
        &body.name,
        &body.member_ids,
        body.is_public,
        body.description.as_deref(),
        body.is_encrypted,
    )
    .await
    .db_ctx("create_group/create")?;

    // Seed default channels for new groups.
    db::channels::create_channel(
        &state.pool,
        group.id,
        "general",
        "text",
        None,
        0,
        Some("Text Channels"),
    )
    .await
    .db_ctx("create_group/create_text_channel")?;
    db::channels::create_channel(
        &state.pool,
        group.id,
        "lounge",
        "voice",
        None,
        0,
        Some("Voice Channels"),
    )
    .await
    .db_ctx("create_group/create_voice_channel")?;

    let members = db::groups::get_group_members(&state.pool, group.id)
        .await
        .db_ctx("create_group/get_members")?;

    let response = GroupResponse {
        id: group.id,
        title: group.title,
        kind: group.kind,
        description: group.description,
        icon_url: group.icon_url,
        members: members
            .into_iter()
            .map(|m| GroupMemberResponse {
                user_id: m.user_id,
                username: m.username,
                role: m.role,
                avatar_url: m.avatar_url,
            })
            .collect(),
    };

    Ok((StatusCode::CREATED, Json(response)))
}

/// GET /api/groups/:id -- Get group info.
pub async fn get_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Verify membership
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("get_group/is_member")?;

    if !is_member {
        return Err(AppError::with_code(
            ErrorCode::NotMember,
            "Not a member of this group",
        ));
    }

    let group = db::groups::get_group(&state.pool, group_id)
        .await
        .db_ctx("get_group/fetch")?
        .ok_or_else(|| AppError::bad_request("Group not found"))?;

    let members = db::groups::get_group_members(&state.pool, group_id)
        .await
        .db_ctx("get_group/get_members")?;

    let response = GroupResponse {
        id: group.id,
        title: group.title,
        kind: group.kind,
        description: group.description,
        icon_url: group.icon_url,
        members: members
            .into_iter()
            .map(|m| GroupMemberResponse {
                user_id: m.user_id,
                username: m.username,
                role: m.role,
                avatar_url: m.avatar_url,
            })
            .collect(),
    };

    Ok(Json(response))
}
