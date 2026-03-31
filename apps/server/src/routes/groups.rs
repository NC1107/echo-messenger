//! Group management REST endpoints.

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

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    pub name: String,
    pub member_ids: Vec<Uuid>,
}

#[derive(Debug, Serialize)]
pub struct GroupResponse {
    pub id: Uuid,
    pub title: Option<String>,
    pub kind: String,
    pub members: Vec<GroupMemberResponse>,
}

#[derive(Debug, Serialize)]
pub struct GroupMemberResponse {
    pub user_id: Uuid,
    pub username: String,
}

#[derive(Debug, Deserialize)]
pub struct AddMemberRequest {
    pub user_id: Uuid,
}

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

    let group = db::groups::create_group(&state.pool, auth.user_id, &body.name, &body.member_ids)
        .await
        .map_err(|e| {
            tracing::error!("Failed to create group: {:?}", e);
            AppError::internal("Failed to create group")
        })?;

    let members = db::groups::get_group_members(&state.pool, group.id)
        .await
        .map_err(|_| AppError::internal("Failed to fetch group members"))?;

    let response = GroupResponse {
        id: group.id,
        title: group.title,
        kind: group.kind,
        members: members
            .into_iter()
            .map(|m| GroupMemberResponse {
                user_id: m.user_id,
                username: m.username,
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
        .map_err(|_| AppError::internal("Database error"))?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    let group = db::groups::get_group(&state.pool, group_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::bad_request("Group not found"))?;

    let members = db::groups::get_group_members(&state.pool, group_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    let response = GroupResponse {
        id: group.id,
        title: group.title,
        kind: group.kind,
        members: members
            .into_iter()
            .map(|m| GroupMemberResponse {
                user_id: m.user_id,
                username: m.username,
            })
            .collect(),
    };

    Ok(Json(response))
}

/// POST /api/groups/:id/members -- Add a member to a group.
pub async fn add_member(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    Json(body): Json<AddMemberRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Verify caller is a member
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    // Verify it's a group conversation
    let kind = db::groups::get_conversation_kind(&state.pool, group_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if kind.as_deref() != Some("group") {
        return Err(AppError::bad_request("Not a group conversation"));
    }

    // Verify target user exists
    let user_exists = db::users::find_by_id(&state.pool, body.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if user_exists.is_none() {
        return Err(AppError::bad_request("User not found"));
    }

    db::groups::add_member(&state.pool, group_id, body.user_id)
        .await
        .map_err(|e| match e {
            sqlx::Error::Database(ref db_err) if db_err.code().as_deref() == Some("23505") => {
                AppError::conflict("User is already a member")
            }
            _ => AppError::internal("Failed to add member"),
        })?;

    Ok(Json(serde_json::json!({ "status": "added" })))
}

/// DELETE /api/groups/:id/members/:user_id -- Remove a member from a group.
pub async fn remove_member(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, target_user_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    // Verify caller is a member
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    let removed = db::groups::remove_member(&state.pool, group_id, target_user_id)
        .await
        .map_err(|_| AppError::internal("Failed to remove member"))?;

    if !removed {
        return Err(AppError::bad_request("User is not a member of this group"));
    }

    Ok(Json(serde_json::json!({ "status": "removed" })))
}

/// POST /api/groups/:id/leave -- Leave a group.
pub async fn leave_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let removed = db::groups::remove_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Failed to leave group"))?;

    if !removed {
        return Err(AppError::bad_request("Not a member of this group"));
    }

    Ok(Json(serde_json::json!({ "status": "left" })))
}
