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
    // TD-15: trim before empty-check; chars().count() for CJK/emoji fairness.
    let trimmed = body.name.trim();
    let char_count = trimmed.chars().count();
    if trimmed.is_empty() || char_count > 100 {
        return Err(AppError::bad_request(
            "Group name must be between 1 and 100 characters",
        ));
    }

    // TD-2: creating an encrypted group without published keys wedges it
    // permanently — the creator can't decrypt their own messages.
    if body.is_encrypted {
        let has_keys = db::keys::has_publishable_keys(&state.pool, auth.user_id)
            .await
            .db_ctx("create_group/has_keys")?;
        if !has_keys {
            return Err(AppError::bad_request(
                "Cannot create an end-to-end-encrypted group before \
                 publishing your identity and one-time prekeys. Open the \
                 app, finish key setup, and try again.",
            ));
        }
    }

    // TD-20: best-effort dup-name check; the read-then-write race is harmless
    // (two duplicates are each independently usable) until the partial index lands.
    if body.is_public {
        let already_exists =
            db::groups::user_has_public_group_named(&state.pool, auth.user_id, trimmed)
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
        trimmed,
        &body.member_ids,
        body.is_public,
        body.description.as_deref(),
        body.is_encrypted,
    )
    .await
    .db_ctx("create_group/create")?;

    let members = db::groups::get_group_members(&state.pool, group.id)
        .await
        .db_ctx("create_group/get_members")?;

    let response = GroupResponse {
        id: group.id,
        title: group.title,
        kind: group.kind,
        description: group.description,
        icon_url: group.icon_url,
        is_encrypted: group.is_encrypted,
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
        is_encrypted: group.is_encrypted,
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
