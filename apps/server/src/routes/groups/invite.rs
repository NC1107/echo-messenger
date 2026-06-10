//! Group invite-link endpoints: create, list, preview, accept, revoke.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::json;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};
use crate::types::Role;
use crate::ws::typing_service::invalidate_member_cache;

use super::super::AppState;
use super::types::CreateInviteRequest;

/// POST /api/groups/:id/invites — generate an invite token (admin/owner only).
pub async fn create_invite(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    body: Option<Json<CreateInviteRequest>>,
) -> Result<impl IntoResponse, AppError> {
    let body = body.map(|b| b.0).unwrap_or_default();

    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("create_invite/get_role")?
        .ok_or_else(|| AppError::forbidden("Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::forbidden(
            "Only owners and admins can create invite links",
        ));
    }

    let expires_at = body
        .expires_in_seconds
        .map(|secs| chrono::Utc::now() + chrono::Duration::seconds(secs));

    // 16 bytes → 22 URL-safe base64 chars (no padding).
    let token = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 16]>());

    let invite = db::groups::create_invite_token(
        &state.pool,
        &token,
        group_id,
        auth.user_id,
        expires_at,
        body.max_uses,
    )
    .await
    .db_ctx("create_invite/insert")?;

    let url = format!("https://echo-messenger.us/invite/t/{}", invite.token);

    Ok((
        StatusCode::CREATED,
        Json(json!({
            "token": invite.token,
            "url": url,
            "conversation_id": invite.conversation_id,
            "created_at": invite.created_at,
            "expires_at": invite.expires_at,
            "max_uses": invite.max_uses,
            "use_count": invite.use_count,
        })),
    ))
}

/// GET /api/groups/:id/invites — list active invite tokens (admin/owner only).
pub async fn list_invites(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("list_invites/get_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::forbidden(
            "Only owners and admins can view invite links",
        ));
    }

    let tokens = db::groups::list_invite_tokens(&state.pool, group_id)
        .await
        .db_ctx("list_invites/query")?;

    let response: Vec<serde_json::Value> = tokens
        .into_iter()
        .map(|t| {
            let url = format!("https://echo-messenger.us/invite/t/{}", t.token);
            json!({
                "token": t.token,
                "url": url,
                "created_at": t.created_at,
                "expires_at": t.expires_at,
                "max_uses": t.max_uses,
                "use_count": t.use_count,
            })
        })
        .collect();

    Ok(Json(response))
}

/// GET /api/invites/:token — lightweight preview of a group (auth required).
///
/// Returns group metadata so the client can show a "Join {name}?" dialog
/// before the user commits. Does not require group membership.
pub async fn get_invite_preview(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(token): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    let invite = db::groups::get_invite_token(&state.pool, &token)
        .await
        .db_ctx("get_invite_preview/lookup")?
        .ok_or_else(|| AppError::not_found("Invite link not found"))?;

    if invite
        .expires_at
        .is_some_and(|exp| chrono::Utc::now() > exp)
    {
        return Err(AppError::not_found("Invite link has expired"));
    }
    if invite.max_uses.is_some_and(|max| invite.use_count >= max) {
        return Err(AppError::bad_request(
            "Invite link has reached its use limit",
        ));
    }

    let preview = db::groups::get_group_preview(&state.pool, invite.conversation_id, auth.user_id)
        .await
        .db_ctx("get_invite_preview/group")?
        .ok_or_else(|| AppError::not_found("Group not found"))?;

    let members = db::groups::get_group_member_previews(&state.pool, invite.conversation_id, 5)
        .await
        .db_ctx("get_invite_preview/members")?;

    Ok(Json(json!({
        "token": invite.token,
        "group": {
            "id": preview.id,
            "title": preview.title,
            "description": preview.description,
            "icon_url": preview.icon_url,
            "member_count": preview.member_count,
            "is_member": preview.is_member,
            "members": members.iter().map(|m| json!({
                "user_id": m.user_id,
                "username": m.username,
                "avatar_url": m.avatar_url,
            })).collect::<Vec<_>>(),
        },
    })))
}

/// POST /api/invites/:token/accept — join the group via an invite token.
pub async fn accept_invite(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(token): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    let invite = db::groups::get_invite_token(&state.pool, &token)
        .await
        .db_ctx("accept_invite/lookup")?
        .ok_or_else(|| AppError::not_found("Invite link not found"))?;

    if invite
        .expires_at
        .is_some_and(|exp| chrono::Utc::now() > exp)
    {
        return Err(AppError::not_found("Invite link has expired"));
    }
    if invite.max_uses.is_some_and(|max| invite.use_count >= max) {
        return Err(AppError::bad_request(
            "Invite link has reached its use limit",
        ));
    }

    let banned = db::groups::is_banned(&state.pool, invite.conversation_id, auth.user_id)
        .await
        .db_ctx("accept_invite/is_banned")?;
    if banned {
        return Err(AppError::bad_request("You are banned from this group"));
    }

    let already_member = db::groups::is_member(&state.pool, invite.conversation_id, auth.user_id)
        .await
        .db_ctx("accept_invite/is_member")?;

    if already_member {
        return Ok(Json(json!({
            "status": "already_member",
            "conversation_id": invite.conversation_id,
        })));
    }

    // #829: surface race-discovered Expired/Exhausted with the same error shape.
    let outcome = db::groups::accept_invite_token(&state.pool, &token, auth.user_id)
        .await
        .db_ctx("accept_invite/insert")?;
    match outcome {
        db::groups::AcceptInviteOutcome::Expired => {
            return Err(AppError::not_found("Invite link has expired"));
        }
        db::groups::AcceptInviteOutcome::Exhausted => {
            return Err(AppError::bad_request(
                "Invite link has reached its use limit",
            ));
        }
        db::groups::AcceptInviteOutcome::Added | db::groups::AcceptInviteOutcome::AlreadyMember => {
        }
    }

    invalidate_member_cache(invite.conversation_id);

    // Broadcast member_added + system message, same pattern as join_group.
    let joiner = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .unwrap_or_default();
    let existing_members =
        db::groups::get_conversation_member_ids(&state.pool, invite.conversation_id)
            .await
            .unwrap_or_default();

    if let Some(joiner_user) = joiner {
        let event = json!({
            "type": "member_added",
            "conversation_id": invite.conversation_id,
            "user_id": auth.user_id,
            "username": joiner_user.username,
            "avatar_url": joiner_user.avatar_url,
            "role": "member",
        });
        if let Ok(s) = serde_json::to_string(&event) {
            state
                .hub
                .broadcast_json(&existing_members, &s, Some(auth.user_id));
        }

        let sentinel = format!(
            "__system__:member_joined:{}:{}",
            auth.user_id, joiner_user.username
        );
        if let Ok(sys_msg) = db::messages::insert_system_message(
            &state.pool,
            invite.conversation_id,
            auth.user_id,
            &sentinel,
        )
        .await
        {
            let all_members =
                db::groups::get_conversation_member_ids(&state.pool, invite.conversation_id)
                    .await
                    .unwrap_or_default();
            let ws_event = json!({
                "type": "new_message",
                "message_id": sys_msg.id,
                "from_user_id": auth.user_id,
                "from_username": joiner_user.username,
                "conversation_id": invite.conversation_id,
                "content": sentinel,
                "timestamp": sys_msg.created_at,
            });
            if let Ok(s) = serde_json::to_string(&ws_event) {
                state.hub.broadcast_json(&all_members, &s, None);
            }
        }
    }

    Ok(Json(json!({
        "status": "joined",
        "conversation_id": invite.conversation_id,
    })))
}

/// DELETE /api/groups/:id/invites/:token — revoke an invite token (admin/owner).
pub async fn revoke_invite(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, token)): Path<(Uuid, String)>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("revoke_invite/get_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::forbidden(
            "Only owners and admins can revoke invite links",
        ));
    }

    let deleted = db::groups::delete_invite_token(&state.pool, &token, group_id)
        .await
        .db_ctx("revoke_invite/delete")?;

    if !deleted {
        return Err(AppError::not_found("Invite token not found"));
    }

    Ok(StatusCode::NO_CONTENT)
}
