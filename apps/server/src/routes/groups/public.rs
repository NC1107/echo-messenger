//! Public group discovery and direct-join endpoints.

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::response::IntoResponse;
use serde_json::json;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};
use crate::ws::typing_service::invalidate_member_cache;

use super::super::AppState;
use super::types::{PublicGroupResponse, PublicGroupsQuery};

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
    .db_ctx("list_public_groups")?;

    let response: Vec<PublicGroupResponse> = groups
        .into_iter()
        .map(|g| PublicGroupResponse {
            id: g.id,
            title: g.title,
            description: g.description,
            icon_url: g.icon_url,
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
        .db_ctx("get_group_preview")?
        .ok_or_else(|| AppError::not_found("Group not found"))?;

    let members = db::groups::get_group_member_previews(&state.pool, group_id, 5)
        .await
        .db_ctx("get_group_preview/members")?;

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
        .db_ctx("join_group/is_banned")?;
    if banned {
        return Err(AppError::bad_request("You are banned from this group"));
    }

    // Check if already a member
    let already_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("join_group/is_member")?;
    if already_member {
        return Err(AppError::with_code(
            ErrorCode::AlreadyMember,
            "Already a member of this group",
        ));
    }

    let joined = db::groups::join_public_group(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("join_group/insert")?;

    if !joined {
        return Err(AppError::bad_request("Group not found or is not public"));
    }

    invalidate_member_cache(group_id);

    // Notify existing members of the new joiner so their member list updates
    // in real time (#660).
    let joiner = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .unwrap_or_default();
    let existing_members = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();
    if let Some(joiner_user) = joiner {
        let event = serde_json::json!({
            "type": "member_added",
            "conversation_id": group_id,
            "user_id": auth.user_id,
            "username": joiner_user.username,
            "avatar_url": joiner_user.avatar_url,
            "role": "member",
        });
        if let Ok(s) = serde_json::to_string(&event) {
            // Exclude the joiner; they reload their own conversation list.
            state
                .hub
                .broadcast_json(&existing_members, &s, Some(auth.user_id));
        }

        // Persist a system message and broadcast as new_message so all
        // members see an in-chat "X joined" pill in real time (#663).
        let sentinel = format!(
            "__system__:member_joined:{}:{}",
            auth.user_id, joiner_user.username
        );
        if let Ok(sys_msg) =
            db::messages::insert_system_message(&state.pool, group_id, auth.user_id, &sentinel)
                .await
        {
            let all_members = db::groups::get_conversation_member_ids(&state.pool, group_id)
                .await
                .unwrap_or_default();
            let ws_event = serde_json::json!({
                "type": "new_message",
                "message_id": sys_msg.id,
                "from_user_id": auth.user_id,
                "from_username": joiner_user.username,
                "conversation_id": group_id,
                "content": sentinel,
                "timestamp": sys_msg.created_at,
            });
            if let Ok(s) = serde_json::to_string(&ws_event) {
                state.hub.broadcast_json(&all_members, &s, None);
            }
        }
    }

    Ok(Json(serde_json::json!({ "status": "joined" })))
}
