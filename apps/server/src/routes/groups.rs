//! Group management REST endpoints.

use axum::Json;
use axum::extract::{Path, Query, State};
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
    #[serde(default)]
    pub is_public: bool,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PublicGroupsQuery {
    pub search: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PublicGroupResponse {
    pub id: Uuid,
    pub title: Option<String>,
    pub member_count: i64,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Serialize)]
pub struct GroupResponse {
    pub id: Uuid,
    pub title: Option<String>,
    pub kind: String,
    pub description: Option<String>,
    pub members: Vec<GroupMemberResponse>,
}

#[derive(Debug, Serialize)]
pub struct GroupMemberResponse {
    pub user_id: Uuid,
    pub username: String,
    pub role: String,
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

    let group = db::groups::create_group_with_visibility(
        &state.pool,
        auth.user_id,
        &body.name,
        &body.member_ids,
        body.is_public,
        body.description.as_deref(),
    )
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
        description: group.description,
        members: members
            .into_iter()
            .map(|m| GroupMemberResponse {
                user_id: m.user_id,
                username: m.username,
                role: m.role,
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
        description: group.description,
        members: members
            .into_iter()
            .map(|m| GroupMemberResponse {
                user_id: m.user_id,
                username: m.username,
                role: m.role,
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
    // Verify caller is a member and get their role
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    // Verify it's a group conversation
    let kind = db::groups::get_conversation_kind(&state.pool, group_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if kind.as_deref() != Some("group") {
        return Err(AppError::bad_request("Not a group conversation"));
    }

    // For private groups, only owner or admin can add members
    let is_public = db::groups::is_public(&state.pool, group_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if !is_public && caller_role != "owner" && caller_role != "admin" {
        return Err(AppError::unauthorized(
            "Only owners and admins can add members to private groups",
        ));
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
    // Verify caller is a member and get their role
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    // If removing someone else, must be owner or admin
    if target_user_id != auth.user_id && caller_role != "owner" && caller_role != "admin" {
        return Err(AppError::unauthorized(
            "Only owners and admins can remove other members",
        ));
    }

    // Prevent removing the owner
    if target_user_id != auth.user_id {
        let target_role = db::groups::get_member_role(&state.pool, group_id, target_user_id)
            .await
            .map_err(|_| AppError::internal("Database error"))?;
        if target_role.as_deref() == Some("owner") {
            return Err(AppError::bad_request("Cannot remove the group owner"));
        }
    }

    let removed = db::groups::remove_member(&state.pool, group_id, target_user_id)
        .await
        .map_err(|_| AppError::internal("Failed to remove member"))?;

    if !removed {
        return Err(AppError::bad_request("User is not a member of this group"));
    }

    Ok(Json(serde_json::json!({ "status": "removed" })))
}

/// GET /api/groups/public -- List public groups.
pub async fn list_public_groups(
    _auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Query(query): Query<PublicGroupsQuery>,
) -> Result<impl IntoResponse, AppError> {
    let groups = db::groups::list_public_groups(&state.pool, query.search.as_deref())
        .await
        .map_err(|e| {
            tracing::error!("Failed to list public groups: {:?}", e);
            AppError::internal("Failed to list public groups")
        })?;

    let response: Vec<PublicGroupResponse> = groups
        .into_iter()
        .map(|g| PublicGroupResponse {
            id: g.id,
            title: g.title,
            member_count: g.member_count,
            created_at: g.created_at,
        })
        .collect();

    Ok(Json(response))
}

/// POST /api/groups/:id/join -- Join a public group.
pub async fn join_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let joined = db::groups::join_public_group(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to join group: {:?}", e);
            AppError::internal("Failed to join group")
        })?;

    if !joined {
        return Err(AppError::bad_request("Group not found or is not public"));
    }

    Ok(Json(serde_json::json!({ "status": "joined" })))
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
