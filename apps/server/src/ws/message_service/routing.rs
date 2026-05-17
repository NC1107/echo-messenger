//! Conversation and channel resolution helpers.
//!
//! These functions map a send-message request (which may carry a raw
//! `conversation_id`, a legacy `to_user_id`, or a `channel_id`) down to the
//! canonical `(conversation_id, Option<channel_id>)` pair that all downstream
//! storage and fanout code operates on.

use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;
use crate::ws::error::send_error;

// ── Conversation resolution ──────────────────────────────────────────────────

/// Resolve the target conversation from either an explicit conversation_id or a to_user_id.
/// Returns None and sends an error to the sender on failure.
pub(in crate::ws::message_service) async fn resolve_conversation(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Option<Uuid>,
    to_user_id: Option<Uuid>,
) -> Option<Uuid> {
    if let Some(cid) = conversation_id {
        // Verify sender is a member of this conversation
        match db::groups::is_member(&state.pool, cid, sender_id).await {
            Ok(true) => Some(cid),
            Ok(false) => {
                send_error(state, sender_id, "Not a member of this conversation");
                None
            }
            Err(_) => {
                send_error(state, sender_id, "Database error");
                None
            }
        }
    } else if let Some(to_uid) = to_user_id {
        // Legacy DM path: verify contacts
        match db::contacts::are_contacts(&state.pool, sender_id, to_uid).await {
            Ok(true) => {}
            Ok(false) => {
                send_error(state, sender_id, "Not a contact");
                return None;
            }
            Err(_) => {
                send_error(state, sender_id, "Database error");
                return None;
            }
        }

        match db::messages::find_or_create_dm_conversation(&state.pool, sender_id, to_uid).await {
            Ok(id) => Some(id),
            Err(_) => {
                send_error(state, sender_id, "Failed to create conversation");
                None
            }
        }
    } else {
        send_error(
            state,
            sender_id,
            "Must provide conversation_id or to_user_id",
        );
        None
    }
}

// ── Channel resolution ───────────────────────────────────────────────────────

/// Resolve the target channel for a message.
/// Returns `Some(Some(channel_id))` for groups, `Some(None)` for DMs, `None` on error.
pub(in crate::ws::message_service) async fn resolve_channel(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
    channel_id: Option<Uuid>,
    conv_kind: Option<ConversationKind>,
) -> Option<Option<Uuid>> {
    if conv_kind != Some(ConversationKind::Group) {
        return Some(None);
    }

    if let Some(cid) = channel_id {
        validate_explicit_channel(state, sender_id, conv_id, cid).await
    } else {
        resolve_default_text_channel(state, sender_id, conv_id).await
    }
}

/// Validate that an explicit channel_id belongs to the conversation and is a text channel.
pub(in crate::ws::message_service) async fn validate_explicit_channel(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
    channel_id: Uuid,
) -> Option<Option<Uuid>> {
    let channel = match db::channels::get_channel(&state.pool, channel_id).await {
        Ok(Some(c)) => c,
        Ok(None) => {
            send_error(state, sender_id, "Channel not found");
            return None;
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return None;
        }
    };

    if channel.conversation_id != conv_id {
        send_error(state, sender_id, "Channel is not part of this conversation");
        return None;
    }

    if channel.kind != "text" {
        send_error(
            state,
            sender_id,
            "Messages can only be sent to text channels",
        );
        return None;
    }

    Some(Some(channel_id))
}

/// Look up the default text channel for a group conversation.
pub(in crate::ws::message_service) async fn resolve_default_text_channel(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
) -> Option<Option<Uuid>> {
    match db::channels::get_default_text_channel(&state.pool, conv_id).await {
        Ok(Some(channel)) => Some(Some(channel.id)),
        Ok(None) => {
            send_error(state, sender_id, "No text channel found for this group");
            None
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            None
        }
    }
}

// ── Reply context ────────────────────────────────────────────────────────────

/// Look up reply context (content and username) for a given reply_to_id,
/// scoped to the conversation the new message will live in.
/// Returns `None` (with a `warn!`) when the parent is missing, deleted,
/// or belongs to a different conversation.
pub(in crate::ws::message_service) async fn lookup_reply_context(
    pool: &sqlx::PgPool,
    reply_to_id: Option<Uuid>,
    conversation_id: Uuid,
) -> (Option<String>, Option<String>) {
    if let Some(rid) = reply_to_id {
        match db::messages::lookup_reply_context(pool, rid, conversation_id).await {
            Ok(Some((c, u))) => (Some(c), Some(u)),
            Ok(None) => {
                tracing::warn!(
                    conversation_id = %conversation_id,
                    reply_to_id = %rid,
                    "reply_to parent not found in conversation; suppressing reply context"
                );
                (None, None)
            }
            Err(e) => {
                tracing::warn!(
                    conversation_id = %conversation_id,
                    reply_to_id = %rid,
                    error = ?e,
                    "lookup_reply_context db error"
                );
                (None, None)
            }
        }
    } else {
        (None, None)
    }
}
