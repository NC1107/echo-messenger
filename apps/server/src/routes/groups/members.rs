//! Group membership management: add, remove, ban, unban.

use axum::Json;
use axum::extract::{Path, State};
use axum::response::IntoResponse;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};
use crate::types::{ConversationKind, Role};
use crate::ws::rotation::{DEFAULT_ROTATION_DEADLINE_MS, elect_rotation_leader, online_subset};
use crate::ws::typing_service::invalidate_member_cache;

use super::super::AppState;

/// Rotate the group key after a member loses access.
///
/// On encrypted groups, bump the conversation's `key_version`, purge every
/// existing per-member envelope (so the kicked user can no longer decrypt
/// future ciphertext, and so a stale envelope cannot be replayed), and
/// broadcast a `group_key_rotation_requested` event to every remaining
/// member.
///
/// **Server-led leader election (Phase 3b).** The event carries
/// `leader_user_id`, `fallback_order`, and `deadline_ms` so receivers know
/// who is expected to fire the rotation first instead of every online
/// member racing to be the one writer. The election is a pure function of
/// the snapshot we take of the WS hub right here — see
/// [`crate::ws::rotation::elect_rotation_leader`] for the rule
/// (lowest-`user_id` online member, no consensus). The
/// `(conversation_id, key_version)` UNIQUE constraint on `group_keys`
/// remains the safety net for the cases this election misses: split
/// brain, retried trigger event, leader crashes between accepting the
/// hint and posting envelopes. Losers of the race still get HTTP 409 and
/// fetch the winner's envelope, just like today — the election only
/// changes which client *starts*, not the correctness floor.
///
/// If no member is online at trigger time the new version is still
/// recorded on the conversation (the kicked user is denied future
/// access either way), but the rotation-requested event is suppressed:
/// nobody can act on it and a deferred-trigger queue is a separate
/// follow-up. The next sender into the group will hit `getGroupKey`,
/// notice the missing envelope, and the existing client-side recovery
/// banner (`docs/group-e2e-design/04-migration-plan.md` Phase 4) takes
/// over.
pub(super) async fn rotate_group_key_after_member_loss(state: &Arc<AppState>, group_id: Uuid) {
    let encrypted = match db::groups::is_encrypted(&state.pool, group_id).await {
        Ok(v) => v,
        Err(e) => {
            tracing::error!("rotate_group_key/is_encrypted({group_id}) failed: {e:?}");
            return;
        }
    };
    if !encrypted {
        return;
    }

    let new_version =
        match db::groups::bump_key_version_and_purge_envelopes(&state.pool, group_id).await {
            Ok(v) => v,
            Err(e) => {
                tracing::error!("rotate_group_key/bump({group_id}) failed: {e:?}");
                return;
            }
        };

    broadcast_rotation_requested(state, group_id, new_version).await;
}

/// Build the `group_key_rotation_requested` event with a server-elected
/// leader and fan it out to the conversation. Extracted from
/// [`rotate_group_key_after_member_loss`] so the bump/purge path and the
/// fan-out path can be reasoned about (and tested) independently.
async fn broadcast_rotation_requested(state: &Arc<AppState>, group_id: Uuid, new_version: i32) {
    let members = match db::groups::get_conversation_member_ids(&state.pool, group_id).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::error!(
                "rotate_group_key/members({group_id}) failed: {e:?} — skipping rotation broadcast"
            );
            return;
        }
    };

    let online = online_subset(&members, |id| state.hub.device_count(id) > 0);
    let elected = elect_rotation_leader(&online);

    let Some(leader) = elected else {
        // No online member can act on this trigger. Suppress the event
        // (it would land in nobody's inbox anyway) and rely on the
        // client-side getGroupKey path to recover when a member next
        // returns. A deferred-trigger queue keyed by reconnect is a
        // sensible follow-up; see CLAUDE.md / docs/group-e2e-design.
        tracing::info!(
            "rotate_group_key({group_id}): no online member at trigger time; \
             new_version={new_version} stored but rotation-requested event suppressed"
        );
        return;
    };

    let event = serde_json::json!({
        "type": "group_key_rotation_requested",
        "conversation_id": group_id,
        "key_version": new_version,
        "leader_user_id": leader.leader,
        "fallback_order": leader.fallback_order,
        "deadline_ms": DEFAULT_ROTATION_DEADLINE_MS,
    });

    crate::ws::broadcast::broadcast_to_conversation(state, group_id, &event).await;
}

/// Broadcast a system-message pill and `new_message` WS event to the group.
///
/// Used when a member is added, removed, or banned so the remaining members
/// see an in-chat notification without polling.
async fn broadcast_member_system_message(
    state: &Arc<AppState>,
    group_id: Uuid,
    actor_user_id: Uuid,
    sentinel: &str,
    target_user_id: Uuid,
    target_username: &str,
    recipients: &[Uuid],
) {
    if let Ok(sys_msg) =
        db::messages::insert_system_message(&state.pool, group_id, actor_user_id, sentinel).await
    {
        let ws_event = serde_json::json!({
            "type": "new_message",
            "message_id": sys_msg.id,
            "from_user_id": target_user_id,
            "from_username": target_username,
            "conversation_id": group_id,
            "content": sentinel,
            "timestamp": sys_msg.created_at,
        });
        if let Ok(s) = serde_json::to_string(&ws_event) {
            state.hub.broadcast_json(recipients, &s, None);
        }
    }
}

/// POST /api/groups/:id/members -- Add a member to a group.
pub async fn add_member(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    Json(body): Json<super::types::AddMemberRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Verify caller is a member and get their role
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("add_member/get_caller_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

    // Verify it's a group conversation
    let kind = db::groups::get_conversation_kind(&state.pool, group_id)
        .await
        .db_ctx("add_member/get_conversation_kind")?;

    if kind.as_deref().and_then(ConversationKind::from_str_opt) != Some(ConversationKind::Group) {
        return Err(AppError::bad_request("Not a group conversation"));
    }

    // For private groups, only owner or admin can add members
    let is_public = db::groups::is_public(&state.pool, group_id)
        .await
        .db_ctx("add_member/is_public")?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !is_public && !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only owners and admins can add members to private groups",
        ));
    }

    // Verify target user exists
    let user_exists = db::users::find_by_id(&state.pool, body.user_id)
        .await
        .db_ctx("add_member/find_user")?;

    if user_exists.is_none() {
        return Err(AppError::bad_request("User not found"));
    }

    // Check if target user is banned
    let banned = db::groups::is_banned(&state.pool, group_id, body.user_id)
        .await
        .db_ctx("add_member/is_banned")?;
    if banned {
        return Err(AppError::bad_request("User is banned from this group"));
    }

    // Check if already an active member
    let already_member = db::groups::is_member(&state.pool, group_id, body.user_id)
        .await
        .db_ctx("add_member/is_member")?;
    if already_member {
        return Err(AppError::with_code(
            ErrorCode::AlreadyMember,
            "User is already a member",
        ));
    }

    let added = db::groups::add_member(&state.pool, group_id, body.user_id)
        .await
        .db_ctx("add_member/insert")?;

    if !added {
        return Err(AppError::with_code(
            ErrorCode::AlreadyMember,
            "User is already a member",
        ));
    }

    invalidate_member_cache(group_id);

    // Notify existing members that someone was added so their member list
    // updates in real time without a manual refresh (#660).
    let new_user = user_exists.unwrap(); // already checked is_some above
    let existing_members = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();
    let event = serde_json::json!({
        "type": "member_added",
        "conversation_id": group_id,
        "user_id": body.user_id,
        "username": new_user.username,
        "avatar_url": new_user.avatar_url,
        "role": "member",
    });
    if let Ok(s) = serde_json::to_string(&event) {
        // Exclude the newly-added user; they get the group via their own
        // loadConversations call after the HTTP 200.
        state
            .hub
            .broadcast_json(&existing_members, &s, Some(body.user_id));
    }

    // Persist a system message and broadcast as new_message so all members see
    // an in-chat "X joined" pill in real time (#663).
    let sentinel = format!(
        "__system__:member_joined:{}:{}",
        body.user_id, new_user.username
    );
    let all_members = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();
    broadcast_member_system_message(
        &state,
        group_id,
        body.user_id,
        &sentinel,
        body.user_id,
        &new_user.username,
        &all_members,
    )
    .await;

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
        .db_ctx("remove_member/get_caller_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

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
            .db_ctx("remove_member/get_target_role")?;
        if target_role.as_deref().and_then(Role::from_str_opt) == Some(Role::Owner) {
            return Err(AppError::bad_request("Cannot remove the group owner"));
        }
    }

    let removed = db::groups::remove_member(&state.pool, group_id, target_user_id)
        .await
        .db_ctx("remove_member/delete")?;

    if !removed {
        return Err(AppError::bad_request("User is not a member of this group"));
    }

    invalidate_member_cache(group_id);

    after_member_loss(
        &state,
        group_id,
        auth.user_id,
        target_user_id,
        "member_removed",
    )
    .await;

    Ok(Json(serde_json::json!({ "status": "removed" })))
}

/// POST /api/groups/:id/ban/:user_id -- Ban a member from a group.
pub async fn ban_member(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, target_user_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("ban_member/get_caller_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only owners and admins can ban members",
        ));
    }

    // Prevent banning the owner or peers of equal rank
    let target_role = db::groups::get_member_role(&state.pool, group_id, target_user_id)
        .await
        .db_ctx("ban_member/get_target_role")?;
    let target_role_enum = target_role
        .as_deref()
        .and_then(Role::from_str_opt)
        .unwrap_or(Role::Member);
    if target_role_enum == Role::Owner {
        return Err(AppError::bad_request("Cannot ban the group owner"));
    }
    if target_role_enum.is_admin_or_above() && caller_role_enum != Role::Owner {
        return Err(AppError::bad_request("Only the group owner can ban admins"));
    }

    db::groups::ban_member(&state.pool, group_id, target_user_id, auth.user_id)
        .await
        .db_ctx("ban_member/insert")?;

    invalidate_member_cache(group_id);

    after_member_loss(
        &state,
        group_id,
        auth.user_id,
        target_user_id,
        "member_banned",
    )
    .await;

    Ok(Json(serde_json::json!({ "status": "banned" })))
}

/// POST /api/groups/:id/unban/:user_id -- Unban a member from a group.
pub async fn unban_member(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, target_user_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("unban_member/get_caller_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only owners and admins can unban members",
        ));
    }

    let unbanned = db::groups::unban_member(&state.pool, group_id, target_user_id)
        .await
        .db_ctx("unban_member/delete")?;

    if !unbanned {
        return Err(AppError::bad_request("User is not banned from this group"));
    }

    Ok(Json(serde_json::json!({ "status": "unbanned" })))
}

/// Shared post-removal logic: auto-delete the group if empty, rotate keys if
/// not, and emit a system-message pill to remaining members.
///
/// `action` is the system-message discriminant: `"member_removed"` or
/// `"member_banned"`.
async fn after_member_loss(
    state: &Arc<AppState>,
    group_id: Uuid,
    actor_user_id: Uuid,
    target_user_id: Uuid,
    action: &str,
) {
    let remaining = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .map_err(|e| tracing::error!("Failed to get member IDs for broadcast: {e:?}"))
        .unwrap_or_default();

    if remaining.is_empty() {
        let _ = db::groups::force_delete_conversation(&state.pool, group_id).await;
        tracing::info!("Auto-deleted empty group {group_id}");
        return;
    }

    // Rotate group key so the removed member can no longer decrypt future messages.
    rotate_group_key_after_member_loss(state, group_id).await;

    // Emit a system message so remaining members see an in-chat pill.
    if let Some(target_user) = db::users::find_by_id(&state.pool, target_user_id)
        .await
        .unwrap_or_default()
    {
        let sentinel = format!(
            "__system__:{}:{}:{}",
            action, target_user_id, target_user.username
        );
        broadcast_member_system_message(
            state,
            group_id,
            actor_user_id,
            &sentinel,
            target_user_id,
            &target_user.username,
            &remaining,
        )
        .await;
    }
}
