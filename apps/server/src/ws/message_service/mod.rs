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
    // GRP2 senders mint this client-side and bind it into the sender
    // signature; the server has to honour it or signature verification
    // breaks (audit OQ-12). Plaintext / GRP1 senders leave it `None`.
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

    // Belt-and-suspenders ciphertext shape gate. When a conversation is marked
    // `is_encrypted`, the server must refuse any payload that isn't shaped like
    // an Echo wire frame (initial V1/V2 or normal-message header). This closes
    // the confidentiality hole left open by client-only enforcement.
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

    // Phase 1.5 (audit P1-2): encrypted-group sender-membership gate.
    //
    // `resolve_conversation` already verifies membership for every send,
    // but the migration plan in `docs/group-e2e-design/04-migration-plan.md`
    // calls out the "kicked member tries to send" attack as a distinct
    // surface that deserves its own structured rejection (`sender-not-member`).
    // Running this only on the encrypted-group branch keeps the signal
    // unambiguous in logs/metrics and adds a defence-in-depth re-check
    // for any future code path that resolves the conversation differently.
    if conv_security.is_encrypted
        && conv_kind == Some(ConversationKind::Group)
        && !enforce_group_sender_membership(state, sender_id, conv_id).await
    {
        return;
    }

    // TD-30: encrypted-DM recipient-inclusion gate. The shape validator
    // already requires `recipient_device_contents` to be non-empty, but it
    // doesn't check that the actual peer is in the map. Without this check
    // a sender could populate only their own devices and let the fanout
    // fallback deliver `legacy_msg` to the peer with whatever bytes pass
    // the structural shape gate.
    if conv_security.is_encrypted
        && conv_kind == Some(ConversationKind::Direct)
        && let Some(rdc) = recipient_device_contents.as_ref()
        && !enforce_dm_recipient_includes_peer(state, sender_id, conv_id, rdc).await
    {
        return;
    }

    // #834 finding 15: parse the wire-shape recipient_device_contents exactly
    // once here, after validation. Downstream consumers (store_and_confirm,
    // fanout_message, build_per_device_json, the self-device-delivery loop)
    // all read the typed `HashMap<Uuid, HashMap<i32, String>>` instead of
    // reparsing the same UUID + i32 fields up to three times per device.
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

    // Bump the dashboard "messages per second" counter exactly once per
    // accepted relay (post-store, pre-fanout). Hot path: a single relaxed
    // atomic fetch-add, no allocation, no lock except for the once-per-second
    // bucket roll inside `MessageRateCounter`.  Carries no per-user or
    // per-content data — see `metrics.rs` for the privacy invariant.
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
