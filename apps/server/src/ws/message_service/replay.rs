//! Offline message replay: deliver queued messages to a reconnecting device.
//!
//! [`deliver_undelivered_messages`] is the entry point, called once per WS
//! connection after the session is registered in the hub.  It uses a
//! cursor-paginated loop over `db::messages::get_undelivered` so a backlog of
//! thousands of messages doesn't stall the receive loop with a single enormous
//! query.
//!
//! Key design points:
//! - Encrypted DMs MUST be replayed using the per-device ciphertext stored in
//!   `message_device_contents`; falling back to `msg.content` ships the
//!   originating device's wire frame, which this device cannot decrypt.
//! - When a per-device row exists for SOME device of this user but not for
//!   THIS device, we emit an `undecryptable` marker so the client can render
//!   a placeholder rather than silently losing the message.
//! - Undecryptable markers are recorded in the per-device ledger
//!   (`mark_device_delivered_batch`) so the same placeholder is not replayed
//!   on the next reconnect (#584).
//! - `messages.delivered` stays `false` for undecryptable frames so sibling
//!   devices that DO have a per-device row can still pick them up.

use axum::extract::ws::Message as WsMessage;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::ws::protocol::ServerMessage;

// ── Entry point ──────────────────────────────────────────────────────────────

/// Deliver any messages that were stored while the user was offline, then mark
/// them delivered and notify the original senders.
///
/// For encrypted DMs, each device has its own ciphertext stored in
/// `message_device_contents`.  A single batch query fetches all per-device
/// ciphertexts for the reconnecting device; the canonical `content` column is
/// used as a fallback when no device-specific row exists (group messages,
/// unencrypted convs, or messages predating multi-device support).
pub(in crate::ws::message_service) async fn deliver_undelivered_messages(
    state: &AppState,
    user_id: Uuid,
    device_id: i32,
) {
    // Cursor-paginated replay; cap iterations against pathological pool errors.
    // Composite (created_at, id) cursor handles same-tick ties.
    const MAX_ITERATIONS: usize = 50; // 50 * 100 = 5 000 messages per reconnect
    let mut after_cursor: Option<(chrono::DateTime<chrono::Utc>, Uuid)> = None;
    for _iter in 0..MAX_ITERATIONS {
        let batch = match db::messages::get_undelivered(
            &state.pool,
            user_id,
            device_id,
            after_cursor,
        )
        .await
        {
            Ok(msgs) => msgs,
            Err(e) => {
                tracing::error!(?e, %user_id, "deliver_undelivered: db error -- aborting replay loop");
                return;
            }
        };

        if batch.is_empty() {
            return;
        }

        // Advance cursor before processing so a continue-on-error inside the
        // loop body can't infinitely re-fetch the same rows.
        let last_cursor = batch.last().map(|m| (m.created_at, m.id));
        let was_full = batch.len() as i64 == db::messages::UNDELIVERED_PAGE_SIZE;
        deliver_one_batch(state, user_id, device_id, batch).await;
        if !was_full {
            return; // last page
        }
        after_cursor = last_cursor;
    }
    tracing::warn!(%user_id, "deliver_undelivered: hit MAX_ITERATIONS, deferring remainder to next reconnect");
}

// ── Batch helpers ────────────────────────────────────────────────────────────

/// Classify a single message for replay given the per-device ciphertext lookup
/// results.
///
/// Returns `(content_to_send, undecryptable_flag)`:
/// - `(device_ct, None)` — we have the right ciphertext for this device.
/// - `("", Some(true))` — another device has a row but not this one; send
///   an undecryptable marker.
/// - `(canonical_content, None)` — no per-device fanout at all (group /
///   plaintext / legacy); send the canonical content.
fn classify_replay_content(
    msg_id: Uuid,
    canonical_content: &str,
    device_ct_map: &std::collections::HashMap<Uuid, String>,
    has_any_device_row: &std::collections::HashSet<Uuid>,
) -> (String, Option<bool>) {
    match device_ct_map.get(&msg_id) {
        Some(c) => (c.clone(), None),
        None if has_any_device_row.contains(&msg_id) => (String::new(), Some(true)),
        None => (canonical_content.to_owned(), None),
    }
}

/// Process a single page of undelivered messages for one device.
async fn deliver_one_batch(
    state: &AppState,
    user_id: Uuid,
    device_id: i32,
    undelivered: Vec<db::messages::MessageWithSender>,
) {
    let all_ids: Vec<Uuid> = undelivered.iter().map(|m| m.id).collect();

    // Batch-fetch all per-device ciphertexts in a single query to avoid N+1.
    let device_ct_map =
        db::messages::get_device_contents_batch(&state.pool, &all_ids, user_id, device_id)
            .await
            .unwrap_or_default();

    // Distinguish "per-device fanout exists but not for this device" from "no
    // per-device fanout" so we ship the right wire (undecryptable vs canonical).
    let has_any_device_row =
        db::messages::message_ids_with_any_device_content(&state.pool, &all_ids, user_id)
            .await
            .unwrap_or_default();

    // Only IDs the hub actually accepted — confirmed enqueue prevents loss.
    let mut delivered_ids: Vec<Uuid> = Vec::with_capacity(undelivered.len());
    let mut delivered_msgs: Vec<&db::messages::MessageWithSender> =
        Vec::with_capacity(undelivered.len());
    // #584: ledger records ALL enqueued frames (including undecryptable
    // placeholders) so this device doesn't re-replay them.
    let mut ledger_ids: Vec<Uuid> = Vec::with_capacity(undelivered.len());

    for msg in &undelivered {
        let (content, undecryptable) =
            classify_replay_content(msg.id, &msg.content, &device_ct_map, &has_any_device_row);

        let server_msg = ServerMessage::NewMessage {
            message_id: msg.id,
            from_user_id: msg.sender_id,
            // Propagate the originating device so the client can pick the
            // correct per-device ratchet on decrypt.
            from_device_id: msg.sender_device_id,
            from_username: msg.sender_username.clone(),
            conversation_id: msg.conversation_id,
            channel_id: msg.channel_id,
            content,
            timestamp: msg.created_at,
            reply_to_id: msg.reply_to_id,
            reply_to_content: msg.reply_to_content.clone(),
            reply_to_username: msg.reply_to_username.clone(),
            thread_root_id: msg.thread_root_id,
            expires_at: None, // Offline delivery: expiry already passed if expired
            undecryptable,
        };
        let Ok(json) = serde_json::to_string(&server_msg) else {
            continue;
        };
        let enqueued = state
            .hub
            .send_to_device(&user_id, device_id, WsMessage::Text(json.into()));
        if !enqueued {
            tracing::warn!(
                message_id = %msg.id,
                user_id = %user_id,
                device_id = device_id,
                "replay: hub rejected message — leaving as undelivered for next reconnect"
            );
            continue;
        }
        if undecryptable.unwrap_or(false) {
            // #584: don't flip messages.delivered (sibling devices may still
            // replay), but ledger this device so it stops re-receiving.
            tracing::warn!(
                message_id = %msg.id,
                user_id = %user_id,
                device_id = device_id,
                "replay: no per-device ciphertext, sent undecryptable marker"
            );
            ledger_ids.push(msg.id);
            continue;
        }
        delivered_ids.push(msg.id);
        ledger_ids.push(msg.id);
        delivered_msgs.push(msg);
    }

    // Bulk-insert per-device ledger entries for every frame accepted by the hub
    // (both decryptable and undecryptable).  Idempotent via ON CONFLICT DO NOTHING.
    let _ = db::messages::mark_device_delivered_batch(&state.pool, &ledger_ids, user_id, device_id)
        .await;

    if delivered_ids.is_empty() {
        return;
    }

    let _ = db::messages::mark_delivered(&state.pool, &delivered_ids).await;

    // Notify original senders that their messages were delivered.
    notify_original_senders(state, delivered_msgs);
}

/// Send `Delivered` events to the original senders of successfully replayed messages.
fn notify_original_senders(
    state: &AppState,
    delivered_msgs: Vec<&db::messages::MessageWithSender>,
) {
    for msg in delivered_msgs {
        let delivered_event = ServerMessage::Delivered {
            message_id: msg.id,
            conversation_id: msg.conversation_id,
        };
        if let Ok(json) = serde_json::to_string(&delivered_event) {
            state
                .hub
                .send_to(&msg.sender_id, WsMessage::Text(json.into()));
        }
    }
}
