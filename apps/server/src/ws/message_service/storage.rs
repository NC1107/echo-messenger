//! Message persistence and sender confirmation.
//!
//! [`store_and_confirm`] is the single write path:
//! 1. Resolves the effective TTL.
//! 2. Persists the message row.
//! 3. Extracts + persists `@mention` rows (plaintext groups only).
//! 4. Persists per-device ciphertexts, skipping blocked recipients.
//! 5. Sends a `MessageSent` confirmation to the originating device.
//! 6. Delivers a `SelfMessage` to the sender's other devices.

use axum::extract::ws::Message as WsMessage;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::ws::error::send_error;
use crate::ws::protocol::ServerMessage;

use super::types::ParsedRecipientDeviceContents;

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Resolve the effective TTL for a message.
///
/// The per-message `ttl_seconds` override takes priority; if absent the
/// conversation-level setting is used.  Values outside `[5, 31_536_000]`
/// (5 s – 1 year) are treated as absent to prevent accidental ephemeral
/// messages with nonsensical lifetimes.
fn resolve_effective_ttl(ttl_seconds: Option<i64>, conv_ttl_seconds: Option<i32>) -> Option<i64> {
    let per_msg = ttl_seconds.filter(|&s| (5..=31_536_000).contains(&s));
    if per_msg.is_some() {
        per_msg
    } else {
        conv_ttl_seconds.map(|v| v as i64)
    }
}

/// Persist `@mention` rows for a plaintext group message.
///
/// Encrypted groups skip this — the canonical content is ciphertext, so
/// there is nothing to scan; their mention badges remain client-side.
/// Errors are logged and swallowed so a mention-table hiccup never blocks
/// the actual send.
async fn persist_mentions(
    pool: &sqlx::PgPool,
    message_id: Uuid,
    conv_id: Uuid,
    sender_id: Uuid,
    content: &str,
    is_encrypted: bool,
) {
    if is_encrypted {
        return;
    }
    match db::mentions::extract_and_persist(pool, message_id, conv_id, sender_id, content).await {
        Ok(0) => {}
        Ok(n) => tracing::debug!(
            message_id = %message_id,
            conversation_id = %conv_id,
            count = n,
            "persisted mentions"
        ),
        Err(e) => tracing::error!(
            message_id = %message_id,
            conversation_id = %conv_id,
            "failed to persist mentions: {e:?}"
        ),
    }
}

/// Persist per-device ciphertexts, skipping recipients that have blocked the sender.
///
/// #829: drop ciphertext destined for recipients that have blocked the
/// sender BEFORE writing to `message_device_contents`. The fanout path
/// already filters blockers out of live delivery, but persisting their
/// rows wastes storage and leaks ciphertext that should never be readable
/// by anyone.
async fn persist_device_contents(
    pool: &sqlx::PgPool,
    message_id: Uuid,
    sender_id: Uuid,
    rdc: &ParsedRecipientDeviceContents,
) {
    let recipient_ids = rdc.recipient_ids();
    let blockers: Vec<Uuid> = if recipient_ids.is_empty() {
        Vec::new()
    } else {
        db::contacts::get_blockers_of(pool, &recipient_ids, sender_id)
            .await
            .unwrap_or_default()
    };

    let entries: Vec<(Uuid, i32, &str)> = rdc
        .by_user
        .iter()
        .filter(|(recipient_id, _)| !blockers.contains(recipient_id))
        .flat_map(|(recipient_id, devices)| {
            devices
                .iter()
                .map(move |(did, ct)| (*recipient_id, *did, ct.as_str()))
        })
        .collect();

    if !entries.is_empty()
        && let Err(e) = db::messages::store_device_contents(pool, message_id, &entries).await
    {
        tracing::error!("Failed to store device contents: {e:?}");
    }
}

/// Send a `MessageSent` confirmation to the originating device.
fn send_message_sent_confirmation(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    stored: &db::messages::MessageRow,
    conv_id: Uuid,
) {
    let confirm = ServerMessage::MessageSent {
        message_id: stored.id,
        conversation_id: conv_id,
        channel_id: stored.channel_id,
        timestamp: stored.created_at,
        expires_at: stored.expires_at,
    };
    if let Ok(json) = serde_json::to_string(&confirm) {
        state
            .hub
            .send_to_device(&sender_id, sender_device_id, WsMessage::Text(json.into()));
    }
}

/// Deliver a `SelfMessage` to every other device belonging to the sender.
///
/// Only the sender's own slice of `recipient_device_contents` is relevant here.
fn deliver_self_messages(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    stored: &db::messages::MessageRow,
    conv_id: Uuid,
    reply_to_id: Option<Uuid>,
    rdc: &ParsedRecipientDeviceContents,
) {
    let Some(self_devices) = rdc.by_user.get(&sender_id) else {
        return;
    };
    for (did, ciphertext) in self_devices {
        if *did == sender_device_id {
            continue; // Don't send to the originating device
        }
        let self_msg = ServerMessage::SelfMessage {
            message_id: stored.id,
            from_device_id: sender_device_id,
            conversation_id: conv_id,
            channel_id: stored.channel_id,
            content: ciphertext.clone(),
            timestamp: stored.created_at,
            reply_to_id,
        };
        if let Ok(json) = serde_json::to_string(&self_msg) {
            state
                .hub
                .send_to_device(&sender_id, *did, WsMessage::Text(json.into()));
        }
    }
}

// ── Public entry point ───────────────────────────────────────────────────────

/// Persist the message to the database, store per-device ciphertexts, send
/// a `message_sent` confirmation to the originating device, and relay the
/// message to the sender's other devices.  Returns the stored message row
/// on success, or `None` after sending an error to the client.
///
/// `conv_ttl_seconds` is the conversation-level disappearing-messages TTL
/// already fetched by `get_conversation_security`; passing it here avoids a
/// second `get_conversation_ttl` round-trip per outbound message.
#[allow(clippy::too_many_arguments)]
pub(in crate::ws::message_service) async fn store_and_confirm(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    conv_id: Uuid,
    resolved_channel_id: Option<Uuid>,
    content: &str,
    reply_to_id: Option<Uuid>,
    recipient_device_contents: Option<&ParsedRecipientDeviceContents>,
    ttl_seconds: Option<i64>,
    conv_ttl_seconds: Option<i32>,
    is_encrypted: bool,
    client_message_id: Option<Uuid>,
) -> Option<db::messages::MessageRow> {
    let effective_ttl = resolve_effective_ttl(ttl_seconds, conv_ttl_seconds);

    // `RowNotFound` here = bad/cross-conversation reply_to_id; surface targeted.
    let stored = match db::messages::store_message(
        &state.pool,
        conv_id,
        resolved_channel_id,
        sender_id,
        Some(sender_device_id),
        content,
        reply_to_id,
        effective_ttl,
        client_message_id,
    )
    .await
    {
        Ok(row) => row,
        Err(sqlx::Error::RowNotFound) if reply_to_id.is_some() => {
            tracing::warn!(
                user_id = %sender_id,
                conversation_id = %conv_id,
                reply_to_id = ?reply_to_id,
                "rejected cross-conversation reply"
            );
            send_error(
                state,
                sender_id,
                "reply_to message not found in this conversation",
            );
            return None;
        }
        Err(sqlx::Error::Database(db_err))
            if db_err.is_unique_violation() && client_message_id.is_some() =>
        {
            // Client UUID collision — typed error so sender retries (re-sign
            // for GRP2) instead of confirming someone else's row.
            tracing::warn!(
                user_id = %sender_id,
                conversation_id = %conv_id,
                client_message_id = ?client_message_id,
                "client-minted message id collision"
            );
            send_error(state, sender_id, "client_message_id collision");
            return None;
        }
        Err(_) => {
            send_error(state, sender_id, "Failed to store message");
            return None;
        }
    };

    persist_mentions(
        &state.pool,
        stored.id,
        conv_id,
        sender_id,
        content,
        is_encrypted,
    )
    .await;

    if let Some(rdc) = recipient_device_contents {
        persist_device_contents(&state.pool, stored.id, sender_id, rdc).await;
    }

    send_message_sent_confirmation(state, sender_id, sender_device_id, &stored, conv_id);

    if let Some(rdc) = recipient_device_contents {
        deliver_self_messages(
            state,
            sender_id,
            sender_device_id,
            &stored,
            conv_id,
            reply_to_id,
            rdc,
        );
    }

    Some(stored)
}
