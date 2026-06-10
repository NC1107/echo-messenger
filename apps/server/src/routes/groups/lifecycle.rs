//! Group lifecycle endpoints: leave, delete.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};
use crate::types::Role;
use crate::ws::typing_service::invalidate_member_cache;

use super::super::AppState;
use super::members::rotate_group_key_after_member_loss;

/// POST /api/groups/:id/leave -- Leave a group.
pub async fn leave_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Owners must transfer ownership before leaving (unless they're the last member)
    let role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("leave_group/get_role")?;
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

    // Look up the leaver's username before removing them so we can emit the
    // system message even after their membership row is gone.
    let leaver = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .unwrap_or_default();

    let removed = db::groups::remove_member(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("leave_group/remove_member")?;

    if !removed {
        return Err(AppError::with_code(
            ErrorCode::NotMember,
            "Not a member of this group",
        ));
    }

    invalidate_member_cache(group_id);

    // VL-24: drop the leaver's voice presence in this conversation so they
    // disappear from the lounge immediately even if their socket stays open.
    crate::ws::events::voice::evict_member_voice_sessions(&state, group_id, auth.user_id).await;

    // Auto-delete group if no members remain
    let remaining = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .map_err(|e| tracing::error!("Failed to get member IDs for broadcast: {e:?}"))
        .unwrap_or_default();
    if remaining.is_empty() {
        let _ = db::groups::force_delete_conversation(&state.pool, group_id).await;
        tracing::info!("Auto-deleted empty group {group_id}");
    } else {
        // Rotate group key so the leaver loses access to future ciphertext.
        rotate_group_key_after_member_loss(&state, group_id).await;

        // Emit a system message so remaining members see an in-chat pill.
        if let Some(leaver_user) = leaver {
            let sentinel = format!(
                "__system__:member_left:{}:{}",
                auth.user_id, leaver_user.username
            );
            if let Ok(sys_msg) =
                db::messages::insert_system_message(&state.pool, group_id, auth.user_id, &sentinel)
                    .await
            {
                let ws_event = serde_json::json!({
                    "type": "new_message",
                    "message_id": sys_msg.id,
                    "from_user_id": auth.user_id,
                    "from_username": leaver_user.username,
                    "conversation_id": group_id,
                    "content": sentinel,
                    "timestamp": sys_msg.created_at,
                });
                if let Ok(s) = serde_json::to_string(&ws_event) {
                    state.hub.broadcast_json(&remaining, &s, None);
                }
            }
        }
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
        .db_ctx("delete_group")?;
    if !deleted {
        return Err(AppError::forbidden(
            "Only the group owner can delete this group",
        ));
    }
    Ok(StatusCode::NO_CONTENT)
}
