//! Group management REST endpoints.

use axum::Json;
use axum::body::Body;
use axum::extract::{Multipart, Path, Query, State};
use axum::http::StatusCode;
use axum::http::header::CONTENT_TYPE;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;
use crate::types::{ConversationKind, Role};

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    pub name: String,
    #[serde(default)]
    pub member_ids: Vec<Uuid>,
    #[serde(default)]
    pub is_public: bool,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PublicGroupsQuery {
    pub search: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct PublicGroupResponse {
    pub id: Uuid,
    pub title: Option<String>,
    pub member_count: i64,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub is_member: bool,
}

#[derive(Debug, Serialize)]
pub struct GroupResponse {
    pub id: Uuid,
    pub title: Option<String>,
    pub kind: String,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    pub members: Vec<GroupMemberResponse>,
}

#[derive(Debug, Serialize)]
pub struct GroupMemberResponse {
    pub user_id: Uuid,
    pub username: String,
    pub role: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct AddMemberRequest {
    pub user_id: Uuid,
}

#[derive(Debug, Deserialize)]
pub struct UpdateGroupRequest {
    pub title: Option<String>,
    pub description: Option<String>,
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

    // Prevent duplicate public group names per creator
    if body.is_public {
        let already_exists =
            db::groups::user_has_public_group_named(&state.pool, auth.user_id, &body.name)
                .await
                .map_err(|e| {
                    tracing::error!("Failed to check duplicate group name: {:?}", e);
                    AppError::internal("Failed to check duplicate group name")
                })?;
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
    )
    .await
    .map_err(|e| {
        tracing::error!("Failed to create group: {:?}", e);
        AppError::internal("Failed to create group")
    })?;

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
    .map_err(|e| {
        tracing::error!("DB error in create_group/create_text_channel: {e:?}");
        AppError::internal("Failed to create default text channel")
    })?;
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
    .map_err(|e| {
        tracing::error!("DB error in create_group/create_voice_channel: {e:?}");
        AppError::internal("Failed to create default voice channel")
    })?;

    let members = db::groups::get_group_members(&state.pool, group.id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in create_group/get_members: {e:?}");
            AppError::internal("Failed to fetch group members")
        })?;

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
        .map_err(|e| {
            tracing::error!("DB error in get_group/is_member: {e:?}");
            AppError::internal("Database error")
        })?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    let group = db::groups::get_group(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_group/fetch: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("Group not found"))?;

    let members = db::groups::get_group_members(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_group/get_members: {e:?}");
            AppError::internal("Database error")
        })?;

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
        .map_err(|e| {
            tracing::error!("DB error in add_member/get_caller_role: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    // Verify it's a group conversation
    let kind = db::groups::get_conversation_kind(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in add_member/get_conversation_kind: {e:?}");
            AppError::internal("Database error")
        })?;

    if kind.as_deref().and_then(ConversationKind::from_str_opt) != Some(ConversationKind::Group) {
        return Err(AppError::bad_request("Not a group conversation"));
    }

    // For private groups, only owner or admin can add members
    let is_public = db::groups::is_public(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in add_member/is_public: {e:?}");
            AppError::internal("Database error")
        })?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !is_public && !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only owners and admins can add members to private groups",
        ));
    }

    // Verify target user exists
    let user_exists = db::users::find_by_id(&state.pool, body.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in add_member/find_user: {e:?}");
            AppError::internal("Database error")
        })?;

    if user_exists.is_none() {
        return Err(AppError::bad_request("User not found"));
    }

    // Check if target user is banned
    let banned = db::groups::is_banned(&state.pool, group_id, body.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in add_member/is_banned: {e:?}");
            AppError::internal("Database error")
        })?;
    if banned {
        return Err(AppError::bad_request("User is banned from this group"));
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
        .map_err(|e| {
            tracing::error!("DB error in remove_member/get_caller_role: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    // If removing someone else, must be owner or admin
    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if target_user_id != auth.user_id && !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only owners and admins can remove other members",
        ));
    }

    // Prevent removing the owner
    if target_user_id != auth.user_id {
        let target_role = db::groups::get_member_role(&state.pool, group_id, target_user_id)
            .await
            .map_err(|e| {
                tracing::error!("DB error in remove_member/get_target_role: {e:?}");
                AppError::internal("Database error")
            })?;
        if target_role.as_deref().and_then(Role::from_str_opt) == Some(Role::Owner) {
            return Err(AppError::bad_request("Cannot remove the group owner"));
        }
    }

    let removed = db::groups::remove_member(&state.pool, group_id, target_user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in remove_member: {e:?}");
            AppError::internal("Failed to remove member")
        })?;

    if !removed {
        return Err(AppError::bad_request("User is not a member of this group"));
    }

    // Auto-delete group if no members remain
    let remaining = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();
    if remaining.is_empty() {
        let _ = db::groups::force_delete_conversation(&state.pool, group_id).await;
        tracing::info!("Auto-deleted empty group {group_id}");
    }

    Ok(Json(serde_json::json!({ "status": "removed" })))
}

/// GET /api/groups/public -- List public groups.
pub async fn list_public_groups(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Query(query): Query<PublicGroupsQuery>,
) -> Result<impl IntoResponse, AppError> {
    let limit = query.limit.unwrap_or(20).clamp(1, 100);
    let offset = query.offset.unwrap_or(0).max(0);

    let groups = db::groups::list_public_groups(
        &state.pool,
        auth.user_id,
        query.search.as_deref(),
        limit,
        offset,
    )
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
            is_member: g.is_member,
        })
        .collect();

    Ok(Json(response))
}

/// GET /api/groups/:id/preview -- Public group preview for invite links.
///
/// Returns group metadata (title, description, avatar, member count,
/// first 5 members) without requiring membership in the group.
/// Private groups return 404 unless the caller is already a member.
pub async fn get_group_preview(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let preview = db::groups::get_group_preview(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_group_preview: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::not_found("Group not found"))?;

    let members = db::groups::get_group_member_previews(&state.pool, group_id, 5)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_group_preview/members: {e:?}");
            AppError::internal("Database error")
        })?;

    Ok(Json(json!({
        "id": preview.id,
        "title": preview.title,
        "description": preview.description,
        "icon_url": preview.icon_url,
        "member_count": preview.member_count,
        "is_public": preview.is_public,
        "is_member": preview.is_member,
        "members": members.iter().map(|m| json!({
            "user_id": m.user_id,
            "username": m.username,
            "avatar_url": m.avatar_url,
            "role": m.role,
        })).collect::<Vec<_>>(),
    })))
}

/// POST /api/groups/:id/join -- Join a public group.
pub async fn join_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Check if user is banned
    let banned = db::groups::is_banned(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in join_group/is_banned: {e:?}");
            AppError::internal("Database error")
        })?;
    if banned {
        return Err(AppError::bad_request("You are banned from this group"));
    }

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
    // Owners must transfer ownership before leaving (unless they're the last member)
    let role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in leave_group/get_role: {e:?}");
            AppError::internal("Database error")
        })?;
    if role.as_deref().and_then(Role::from_str_opt) == Some(Role::Owner) {
        let members = db::groups::get_conversation_member_ids(&state.pool, group_id)
            .await
            .unwrap_or_default();
        if members.len() > 1 {
            return Err(AppError::bad_request(
                "Transfer ownership before leaving the group",
            ));
        }
    }

    let removed = db::groups::remove_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in leave_group/remove_member: {e:?}");
            AppError::internal("Failed to leave group")
        })?;

    if !removed {
        return Err(AppError::bad_request("Not a member of this group"));
    }

    // Auto-delete group if no members remain
    let remaining = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();
    if remaining.is_empty() {
        // delete_group checks owner, but we just need a raw delete for empty groups
        let _ = db::groups::force_delete_conversation(&state.pool, group_id).await;
        tracing::info!("Auto-deleted empty group {group_id}");
    }

    Ok(Json(serde_json::json!({ "status": "left" })))
}

/// DELETE /api/groups/:id -- Delete a group (owner only).
pub async fn delete_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let deleted = db::groups::delete_group(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in delete_group: {e:?}");
            AppError::internal("Failed to delete group")
        })?;
    if !deleted {
        return Err(AppError::unauthorized(
            "Only the group owner can delete this group",
        ));
    }
    Ok(StatusCode::NO_CONTENT)
}

/// PUT /api/groups/:id -- Update group metadata (owner/admin only).
pub async fn update_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    Json(body): Json<UpdateGroupRequest>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in update_group/get_role: {e:?}");
            AppError::internal("Failed to check role")
        })?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only the group owner or admin can update the group",
        ));
    }

    if let Some(title) = &body.title {
        let trimmed = title.trim();
        if trimmed.is_empty() {
            return Err(AppError::bad_request("Title cannot be empty"));
        }
        db::groups::update_group_title(&state.pool, group_id, trimmed)
            .await
            .map_err(|e| {
                tracing::error!("DB error in update_group/title: {e:?}");
                AppError::internal("Failed to update group title")
            })?;
    }

    if let Some(ref desc) = body.description {
        db::groups::update_group_description(&state.pool, group_id, desc)
            .await
            .map_err(|e| {
                tracing::error!("DB error in update_group/description: {e:?}");
                AppError::internal("Failed to update description")
            })?;
    }

    Ok(Json(serde_json::json!({ "status": "updated" })))
}

// ---------------------------------------------------------------------------
// POST /api/groups/:id/ban/:user_id -- Ban a member from a group
// ---------------------------------------------------------------------------

pub async fn ban_member(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, target_user_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ban_member/get_caller_role: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only owners and admins can ban members",
        ));
    }

    // Prevent banning the owner
    let target_role = db::groups::get_member_role(&state.pool, group_id, target_user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ban_member/get_target_role: {e:?}");
            AppError::internal("Database error")
        })?;
    if target_role.as_deref().and_then(Role::from_str_opt) == Some(Role::Owner) {
        return Err(AppError::bad_request("Cannot ban the group owner"));
    }

    db::groups::ban_member(&state.pool, group_id, target_user_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ban_member: {e:?}");
            AppError::internal("Failed to ban member")
        })?;

    // Auto-delete group if no members remain
    let remaining = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();
    if remaining.is_empty() {
        let _ = db::groups::force_delete_conversation(&state.pool, group_id).await;
        tracing::info!("Auto-deleted empty group {group_id}");
    }

    Ok(Json(serde_json::json!({ "status": "banned" })))
}

// ---------------------------------------------------------------------------
// POST /api/groups/:id/unban/:user_id -- Unban a member from a group
// ---------------------------------------------------------------------------

pub async fn unban_member(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, target_user_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in unban_member/get_caller_role: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only owners and admins can unban members",
        ));
    }

    let unbanned = db::groups::unban_member(&state.pool, group_id, target_user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in unban_member: {e:?}");
            AppError::internal("Failed to unban member")
        })?;

    if !unbanned {
        return Err(AppError::bad_request("User is not banned from this group"));
    }

    Ok(Json(serde_json::json!({ "status": "unbanned" })))
}

// ---------------------------------------------------------------------------
// Group avatar upload/download
// ---------------------------------------------------------------------------

/// Maximum group avatar size: 2 MB.
const MAX_GROUP_AVATAR_SIZE: usize = 2 * 1024 * 1024;

/// Allowed group avatar MIME types.
const ALLOWED_GROUP_AVATAR_TYPES: &[&str] = &["image/jpeg", "image/png", "image/webp"];

fn avatar_extension_for_mime(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        _ => "bin",
    }
}

fn avatar_mime_for_extension(ext: &str) -> &str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        _ => "application/octet-stream",
    }
}

/// PUT /api/groups/:id/avatar -- Upload a group avatar (owner/admin only).
///
/// Accepts multipart form data with an `avatar` field. Saves to
/// `./uploads/avatars/group_{id}.{ext}` and sets `icon_url` on the
/// conversation row.
pub async fn upload_group_avatar(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    mut multipart: Multipart,
) -> Result<impl IntoResponse, AppError> {
    // Verify caller is owner or admin
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in upload_group_avatar/get_role: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only the group owner or admin can change the avatar",
        ));
    }

    fs::create_dir_all("./uploads/avatars")
        .await
        .map_err(|e| AppError::internal(format!("Failed to create avatars directory: {e}")))?;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::bad_request(format!("Invalid multipart data: {e}")))?
    {
        let field_name = field.name().unwrap_or_default().to_string();
        if field_name != "avatar" {
            continue;
        }

        let mime_type = field
            .content_type()
            .unwrap_or("application/octet-stream")
            .to_string();

        if !ALLOWED_GROUP_AVATAR_TYPES.contains(&mime_type.as_str()) {
            return Err(AppError::bad_request(format!(
                "Avatar type '{mime_type}' is not allowed. \
                 Allowed: {}",
                ALLOWED_GROUP_AVATAR_TYPES.join(", ")
            )));
        }

        let data = field
            .bytes()
            .await
            .map_err(|e| AppError::bad_request(format!("Failed to read avatar data: {e}")))?;

        if data.len() > MAX_GROUP_AVATAR_SIZE {
            return Err(AppError::bad_request(format!(
                "Avatar too large. Maximum size is {} bytes",
                MAX_GROUP_AVATAR_SIZE
            )));
        }

        let ext = avatar_extension_for_mime(&mime_type);
        let disk_filename = format!("group_{group_id}.{ext}");
        let disk_path = format!("./uploads/avatars/{disk_filename}");

        // Remove old avatar files for this group (different extensions)
        for old_ext in &["jpg", "png", "webp"] {
            let old = format!("./uploads/avatars/group_{group_id}.{old_ext}");
            let _ = fs::remove_file(&old).await;
        }

        fs::write(&disk_path, &data)
            .await
            .map_err(|e| AppError::internal(format!("Failed to save avatar: {e}")))?;

        let icon_url = format!("/api/groups/{group_id}/avatar");
        db::groups::update_group_icon_url(&state.pool, group_id, &icon_url)
            .await
            .map_err(|e| {
                tracing::error!("DB error in upload_group_avatar/set_icon: {e:?}");
                AppError::internal("Failed to update group avatar")
            })?;

        return Ok((StatusCode::OK, Json(json!({ "avatar_url": icon_url }))));
    }

    Err(AppError::bad_request(
        "Missing 'avatar' field in multipart form data",
    ))
}

/// GET /api/groups/:id/avatar -- Serve the group avatar image.
/// Public endpoint — no auth required.
pub async fn get_group_avatar(
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<Response, AppError> {
    let icon_url = db::groups::get_group_icon_url(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_group_avatar/icon_url: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this group".to_string(),
        })?;

    let expected = format!("/api/groups/{group_id}/avatar");
    if icon_url != expected {
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this group".to_string(),
        });
    }

    for ext in &["jpg", "png", "webp"] {
        let disk_path = format!("./uploads/avatars/group_{group_id}.{ext}");
        if let Ok(data) = fs::read(&disk_path).await {
            let mime = avatar_mime_for_extension(ext);
            let response = Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, mime)
                .body(Body::from(data))
                .map_err(|e| AppError::internal(format!("Failed to build response: {e}")))?;
            return Ok(response);
        }
    }

    Err(AppError {
        status: StatusCode::NOT_FOUND,
        message: "Avatar file not found on disk".to_string(),
    })
}
