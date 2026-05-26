//! Message send, fanout, and delivery logic.
//!
//! Public surface (unchanged from the original monolithic `message_service.rs`):
//! - [`handle_send_message`] — handle a `SendMessage` client frame
//! - [`deliver_undelivered_messages`] — replay offline queue on reconnect
//!
//! Internal organisation:
//! - `types`    — shared data types
//! - `validate` — input-validation helpers (wire-frame shape, length, encryption)
//! - `routing`  — conversation and channel resolution
//! - `storage`  — persistence + sender confirmation (`store_and_confirm`)
//! - `fanout`   — multi-device delivery to all conversation members
//! - `replay`   — offline message replay on reconnect

mod fanout;
mod replay;
mod routing;
mod storage;
mod types;
mod validate;

use uuid::Uuid;

use crate::routes::AppState;
use crate::types::ConversationKind;
use crate::ws::protocol::ServerMessage;

use fanout::fanout_message;
use replay::deliver_undelivered_messages as deliver_undelivered_impl;
use routing::{lookup_reply_context, resolve_conversation};
use storage::store_and_confirm;
use types::{ParsedRecipientDeviceContents, RecipientDeviceContents};
use validate::{
    enforce_dm_recipient_includes_peer, enforce_group_sender_membership,
    validate_conversation_security, validate_encrypted_payload, validate_message_length,
};

// ── External API ─────────────────────────────────────────────────────────────

/// Replay any messages stored while the user was offline.
///
/// Called by `ws::handler` once per WS connection after the session is
/// registered in the hub.
pub(super) async fn deliver_undelivered_messages(state: &AppState, user_id: Uuid, device_id: i32) {
    deliver_undelivered_impl(state, user_id, device_id).await;
}

/// Orchestrate a full `SendMessage` client frame:
/// validate → resolve → store → fanout.
#[allow(clippy::too_many_arguments)]
pub(super) async fn handle_send_message(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    sender_username: &str,
    conversation_id: Option<Uuid>,
    channel_id: Option<Uuid>,
    to_user_id: Option<Uuid>,
    content: String,
    reply_to_id: Option<Uuid>,
    recipient_device_contents: Option<RecipientDeviceContents>,
    ttl_seconds: Option<i64>,
    // GRP2: client-minted, bound into the sender signature (OQ-12). The server
    // MUST honour it or signature verification breaks.
    client_message_id: Option<Uuid>,
) {
    if !validate_message_length(state, sender_id, &content) {
        return;
    }

    let Some(conv_id) = resolve_conversation(state, sender_id, conversation_id, to_user_id).await
    else {
        return;
    };

    let Some((conv_security, conv_kind, resolved_channel_id)) =
        validate_conversation_security(state, sender_id, conv_id, channel_id).await
    else {
        return;
    };

    // Server-side ciphertext shape gate: refuse non-wire-frame payloads on
    // encrypted conversations (closes the client-only enforcement hole).
    if conv_security.is_encrypted
        && !validate_encrypted_payload(
            state,
            sender_id,
            conv_id,
            conv_kind,
            &content,
            recipient_device_contents.as_ref(),
        )
    {
        return;
    }

    // P1-2: encrypted-group sender-membership re-check (kicked-member attack);
    // structured `sender-not-member` rejection + defence-in-depth.
    if conv_security.is_encrypted
        && conv_kind == Some(ConversationKind::Group)
        && !enforce_group_sender_membership(state, sender_id, conv_id).await
    {
        return;
    }

    // TD-30: encrypted-DM peer must be in `recipient_device_contents`, else
    // a sender could ship arbitrary bytes via the legacy fallback.
    if conv_security.is_encrypted
        && conv_kind == Some(ConversationKind::Direct)
        && let Some(rdc) = recipient_device_contents.as_ref()
        && !enforce_dm_recipient_includes_peer(state, sender_id, conv_id, rdc).await
    {
        return;
    }

    // #834 finding 15: parse rdc once instead of reparsing per device downstream.
    let parsed_rdc = recipient_device_contents
        .as_ref()
        .map(ParsedRecipientDeviceContents::from_wire);

    let (reply_content, reply_username) =
        lookup_reply_context(&state.pool, reply_to_id, conv_id).await;

    // Store message, send confirmation, and deliver to sender's other devices.
    let Some(stored) = store_and_confirm(
        state,
        sender_id,
        sender_device_id,
        conv_id,
        resolved_channel_id,
        &content,
        reply_to_id,
        parsed_rdc.as_ref(),
        ttl_seconds,
        conv_security.disappearing_ttl_seconds,
        conv_security.is_encrypted,
        client_message_id,
    )
    .await
    else {
        return;
    };

    // Aggregate rate only — privacy invariant in `metrics.rs`.
    state.message_rate.record();

    let deliver = ServerMessage::NewMessage {
        message_id: stored.id,
        from_user_id: sender_id,
        from_device_id: Some(sender_device_id),
        from_username: sender_username.to_string(),
        conversation_id: conv_id,
        channel_id: stored.channel_id,
        content,
        timestamp: stored.created_at,
        reply_to_id,
        reply_to_content: reply_content,
        reply_to_username: reply_username,
        expires_at: stored.expires_at,
        undecryptable: None,
    };

    fanout_message(
        state,
        sender_id,
        sender_device_id,
        conv_id,
        &deliver,
        stored.id,
        conv_security.is_encrypted,
        conv_kind == Some(ConversationKind::Group),
        parsed_rdc,
    )
    .await;
}
