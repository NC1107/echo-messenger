//! Message fan-out: deliver a stored message to all conversation members.
//!
//! Responsibilities:
//! - Filter blocked and sender-self recipients.
//! - Strip revoked devices from per-device ciphertext maps (#657).
//! - Build per-device `WsMessage` values once before the loop (#690).
//! - Track which device queues accepted the frame; batch-insert into the
//!   per-device delivery ledger (#829).
//! - Suppress offline push when `@here` appears in a plaintext group (#451).
//! - Spawn APNs/FCM push notifications for offline members.

use std::collections::HashMap;

use axum::extract::ws::Message as WsMessage;
use chrono::{DateTime, Utc};
use smallvec::SmallVec;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::ws::protocol::ServerMessage;
use crate::ws::typing_service::get_member_ids_cached;

use super::types::ParsedRecipientDeviceContents;

// ── NewMessageFields ─────────────────────────────────────────────────────────

/// Common fields extracted from a `ServerMessage::NewMessage` for per-device
/// rewriting and push notification content.
pub(in crate::ws::message_service) struct NewMessageFields {
    pub(super) message_id: Uuid,
    pub(super) from_user_id: Uuid,
    pub(super) from_device_id: Option<i32>,
    pub(super) from_username: String,
    pub(super) conversation_id: Uuid,
    pub(super) channel_id: Option<Uuid>,
    pub(super) content: String,
    pub(super) timestamp: DateTime<Utc>,
    pub(super) reply_to_id: Option<Uuid>,
    pub(super) reply_to_content: Option<String>,
    pub(super) reply_to_username: Option<String>,
    pub(super) expires_at: Option<DateTime<Utc>>,
}

impl NewMessageFields {
    /// Extract fields from a `ServerMessage::NewMessage`, returning `None` for other variants.
    pub(super) fn extract(message: &ServerMessage) -> Option<Self> {
        match message {
            ServerMessage::NewMessage {
                message_id,
                from_user_id,
                from_device_id,
                from_username,
                conversation_id,
                channel_id,
                content,
                timestamp,
                reply_to_id,
                reply_to_content,
                reply_to_username,
                expires_at,
                undecryptable: _,
            } => Some(Self {
                message_id: *message_id,
                from_user_id: *from_user_id,
                from_device_id: *from_device_id,
                from_username: from_username.clone(),
                conversation_id: *conversation_id,
                channel_id: *channel_id,
                content: content.clone(),
                timestamp: *timestamp,
                reply_to_id: *reply_to_id,
                reply_to_content: reply_to_content.clone(),
                reply_to_username: reply_to_username.clone(),
                expires_at: *expires_at,
            }),
            _ => None,
        }
    }
}

// ── Per-device JSON ──────────────────────────────────────────────────────────

/// Pre-serialize per-device JSON messages once for each recipient to avoid
/// re-serializing the same message for every member in the fanout loop.
/// Outer key is `recipient_user_id`, inner is `device_id -> WsMessage`.
///
/// TD-61: serialise the invariant portion **once** as a String around a
/// content-shaped sentinel, then per device splice the JSON-encoded
/// ciphertext between the resulting prefix/suffix slices. The previous
/// implementation called `base_value.clone()` per device, which walked the
/// 8-field Object tree and string-cloned every leaf — for a 50-member ×
/// 3-device group that's 150 deep clones per fanout. Sentinel-splice is
/// O(devices × ciphertext_len) with no extra allocations beyond the final
/// `WsMessage::Text` buffer.
pub(in crate::ws::message_service) fn build_per_device_json(
    fields: &NewMessageFields,
    recipient_device_contents: &ParsedRecipientDeviceContents,
) -> HashMap<Uuid, Vec<(i32, WsMessage)>> {
    // Per-call UUID sentinel; cannot collide with any legitimate JSON content.
    let sentinel = format!("__ECHO_CONTENT_PLACEHOLDER_{}__", Uuid::new_v4());

    let base_msg = ServerMessage::NewMessage {
        message_id: fields.message_id,
        from_user_id: fields.from_user_id,
        from_device_id: fields.from_device_id,
        from_username: fields.from_username.clone(),
        conversation_id: fields.conversation_id,
        channel_id: fields.channel_id,
        content: sentinel.clone(),
        timestamp: fields.timestamp,
        reply_to_id: fields.reply_to_id,
        reply_to_content: fields.reply_to_content.clone(),
        reply_to_username: fields.reply_to_username.clone(),
        expires_at: fields.expires_at,
        undecryptable: None,
    };

    let Ok(serialized) = serde_json::to_string(&base_msg) else {
        return HashMap::new();
    };

    // Sentinel is ASCII-safe so the JSON-escaped form is just `"<sentinel>"`.
    let sentinel_quoted = format!("\"{sentinel}\"");
    let Some(pos) = serialized.find(&sentinel_quoted) else {
        return HashMap::new();
    };
    let prefix = &serialized[..pos];
    let suffix = &serialized[pos + sentinel_quoted.len()..];

    recipient_device_contents
        .by_user
        .iter()
        .map(|(recipient_id, devices)| {
            let entries: Vec<(i32, WsMessage)> = devices
                .iter()
                .filter_map(|(did, ciphertext)| {
                    // JSON-encode the ciphertext string in isolation, then
                    // concat into the pre-built prefix/suffix.
                    let ct_json = serde_json::to_string(ciphertext).ok()?;
                    let mut frame =
                        String::with_capacity(prefix.len() + ct_json.len() + suffix.len());
                    frame.push_str(prefix);
                    frame.push_str(&ct_json);
                    frame.push_str(suffix);
                    Some((*did, WsMessage::Text(frame.into())))
                })
                .collect();
            (*recipient_id, entries)
        })
        .collect()
}

// ── Per-member delivery ──────────────────────────────────────────────────────

/// Outcome of a fan-out delivery attempt to a single conversation member.
///
/// `accepted_device_ids` lists the device IDs whose outbound queues actually
/// accepted the frame on the per-device path -- the caller uses these to
/// populate the per-device delivery ledger so sibling devices that come
/// online later still replay the message (#829).
pub(in crate::ws::message_service) struct MemberDeliveryOutcome {
    pub delivered: bool,
    /// SmallVec keeps the typical 1-4 device case heap-free; spills to
    /// the heap automatically for users with more devices (#834).
    pub accepted_device_ids: SmallVec<[i32; 4]>,
}

/// Deliver a message to a single member via per-device or legacy delivery.
/// Returns `true` if the member received the message on at least one device.
///
/// Both `per_recipient_json` entries and `legacy_msg` are `WsMessage::Text`
/// (Bytes-backed); cloning inside the loop is O(1) — no string copying (#690).
pub(in crate::ws::message_service) fn deliver_to_member(
    hub: &crate::ws::hub::Hub,
    member_id: &Uuid,
    per_recipient_json: Option<&HashMap<Uuid, Vec<(i32, WsMessage)>>>,
    legacy_msg: Option<&WsMessage>,
) -> MemberDeliveryOutcome {
    if let Some(by_recipient) = per_recipient_json
        && let Some(device_msgs) = by_recipient.get(member_id)
    {
        // Deliver to ALL recipient devices; OR-accumulate instead of short-circuiting
        // so a successful send to device #1 doesn't skip device #2.
        let mut accepted: SmallVec<[i32; 4]> = SmallVec::with_capacity(device_msgs.len());
        for (did, msg) in device_msgs {
            // WsMessage::Text is Bytes-backed; clone is O(1).
            if hub.send_to_device(member_id, *did, msg.clone()) {
                accepted.push(*did);
            }
        }
        return MemberDeliveryOutcome {
            delivered: !accepted.is_empty(),
            accepted_device_ids: accepted,
        };
    }
    if let Some(msg) = legacy_msg {
        // #829: legacy path also needs to populate the per-device ledger so
        // late-arriving sibling devices don't re-replay via `get_undelivered`.
        let accepted = hub.send_to_user_collecting(member_id, msg.clone());
        return MemberDeliveryOutcome {
            delivered: !accepted.is_empty(),
            accepted_device_ids: accepted,
        };
    }
    MemberDeliveryOutcome {
        delivered: false,
        accepted_device_ids: SmallVec::new(),
    }
}

// ── Delivery confirmation ────────────────────────────────────────────────────

/// Mark messages as delivered in the DB and send a delivery confirmation back to the sender.
///
/// #829: the `messages.delivered` flag is no longer the gate for `get_undelivered`
/// replay -- the per-device `message_deliveries` ledger is. This function exists
/// purely for the sender's read-receipt UI: it tells the sending client "at least
/// one recipient device accepted this frame". Sibling-device replay correctness
/// is handled by `mark_devices_delivered_pairs` in `fanout_message`.
pub(in crate::ws::message_service) async fn send_delivery_confirmation(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    stored_id: Uuid,
    conv_id: Uuid,
) {
    let _ = db::messages::mark_delivered(&state.pool, &[stored_id]).await;

    let delivered_event = ServerMessage::Delivered {
        message_id: stored_id,
        conversation_id: conv_id,
    };
    if let Ok(delivered_json) = serde_json::to_string(&delivered_event) {
        state.hub.send_to_device(
            &sender_id,
            sender_device_id,
            WsMessage::Text(delivered_json.into()),
        );
    }
}

// ── Push notifications ───────────────────────────────────────────────────────

/// Spawn a background task to send push notifications to offline users.
pub(in crate::ws::message_service) fn spawn_push_notifications(
    pool: sqlx::PgPool,
    offline_user_ids: Vec<Uuid>,
    sender_name: &str,
    content: &str,
    is_encrypted: bool,
    conv_id: Uuid,
    stored_id: Uuid,
) {
    let sender_name = sender_name.to_string();
    let content = content.to_string();
    let handle = tokio::spawn(async move {
        crate::push::notify_offline_users(
            &pool,
            &offline_user_ids,
            &sender_name,
            &content,
            is_encrypted,
            conv_id,
            stored_id,
        )
        .await;
    });
    tokio::spawn(async move {
        if let Err(e) = handle.await {
            tracing::error!("Push notification task failed for conv {conv_id}: {e}");
        }
    });
}

// ── Revoked-device filter ────────────────────────────────────────────────────

/// Strip ciphertexts destined for explicitly revoked devices (#657).
///
/// Devices with NO `identity_keys` row at all (test fixtures, fresh
/// registrations) are passed through unchanged — only rows with a non-NULL
/// `revoked_at` are dropped.
async fn filter_revoked_devices(
    pool: &sqlx::PgPool,
    mut rdc: ParsedRecipientDeviceContents,
) -> ParsedRecipientDeviceContents {
    let recipient_ids = rdc.recipient_ids();
    let revoked_map = db::keys::get_revoked_devices_for_users(pool, &recipient_ids)
        .await
        .unwrap_or_default();
    if !revoked_map.is_empty() {
        for (uid, devices) in rdc.by_user.iter_mut() {
            if let Some(revoked_dids) = revoked_map.get(uid) {
                devices.retain(|did, _| !revoked_dids.contains(did));
            }
        }
    }
    rdc
}

// ── @here suppression ────────────────────────────────────────────────────────

/// Decide whether offline push should be suppressed for this message.
///
/// `@here` in a plaintext group silences APNs/FCM for members that are
/// currently offline. Encrypted groups, DMs, and `@everyone` are unaffected.
/// See the full design rationale in the inline comments below.
fn should_suppress_offline_push(
    offline_count: usize,
    is_group: bool,
    is_encrypted: bool,
    content: &str,
) -> bool {
    // Fast-exit: nothing to suppress when everyone is online.
    if offline_count == 0 {
        return false;
    }
    // `@here` is a group-only concept; in a 1:1 DM the literal text "@here"
    // is just a string and must not silently drop the recipient's push.
    if !is_group {
        return false;
    }
    // Encrypted groups: the server can't read the ciphertext, so `@here`
    // will never appear literally inside it.
    if is_encrypted {
        return false;
    }
    // `@everyone` does NOT suppress offline push: by design it should notify
    // every member, online or not.
    db::mentions::is_standalone_keyword(content, "here")
}

// ── Public entry point ───────────────────────────────────────────────────────

/// Fan out a message to all conversation members (except sender), with block
/// filtering and delivery tracking. Supports per-device ciphertext delivery
/// for multi-device.
#[allow(clippy::too_many_arguments)]
pub(in crate::ws::message_service) async fn fanout_message(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    conv_id: Uuid,
    message: &ServerMessage,
    stored_id: Uuid,
    is_encrypted: bool,
    is_group: bool,
    recipient_device_contents: Option<ParsedRecipientDeviceContents>,
) {
    let Some(fields) = NewMessageFields::extract(message) else {
        tracing::error!("fanout_message called with non-NewMessage variant");
        return;
    };

    let member_ids = match get_member_ids_cached(&state.pool, conv_id).await {
        Ok(ids) => ids,
        Err(_) => {
            tracing::error!("Failed to get conversation members for fan-out");
            return;
        }
    };

    // Batch check which members have blocked the sender (single query instead of N+1).
    let blockers: Vec<Uuid> = db::contacts::get_blockers_of(&state.pool, &member_ids, sender_id)
        .await
        .unwrap_or_default();

    // #657: Strip ciphertexts destined for explicitly revoked devices before
    // building per-device frames.
    let recipient_device_contents = match recipient_device_contents {
        Some(rdc) => Some(filter_revoked_devices(&state.pool, rdc).await),
        None => None,
    };

    // #690: pre-build per-recipient frames so the fanout loop only does
    // O(1) Bytes-backed clones, no serialization per recipient.
    let per_recipient_json = recipient_device_contents
        .as_ref()
        .map(|rdc| build_per_device_json(&fields, rdc));
    let legacy_msg = serde_json::to_string(message)
        .ok()
        .map(|s| WsMessage::Text(s.into()));

    let mut any_delivered = false;
    let mut offline_user_ids = Vec::new();
    // #829: accepted (user, device) pairs feed the per-device ledger so late
    // siblings don't replay via `get_undelivered`.
    let mut accepted_device_pairs: Vec<(Uuid, i32)> = Vec::new();

    let eligible = member_ids
        .iter()
        .filter(|id| **id != sender_id && !blockers.contains(id));

    for member_id in eligible {
        let outcome = deliver_to_member(
            &state.hub,
            member_id,
            per_recipient_json.as_ref(),
            legacy_msg.as_ref(),
        );
        if outcome.delivered {
            any_delivered = true;
        } else {
            offline_user_ids.push(*member_id);
        }
        for did in outcome.accepted_device_ids {
            accepted_device_pairs.push((*member_id, did));
        }
    }

    // #829: per-device ledger is the authoritative replay gate (the global
    // `messages.delivered` flag only feeds read-receipt UI now).
    if !accepted_device_pairs.is_empty()
        && let Err(e) = db::messages::mark_devices_delivered_pairs(
            &state.pool,
            stored_id,
            &accepted_device_pairs,
        )
        .await
    {
        tracing::error!(
            message_id = %stored_id,
            "failed to populate per-device delivery ledger on fanout: {e:?}"
        );
    }

    if any_delivered {
        send_delivery_confirmation(state, sender_id, sender_device_id, stored_id, conv_id).await;
    }

    // #451: `@here` only notifies online members. Body inspection is gated on
    // `!is_encrypted` so encrypted groups are unaffected.
    let suppress_offline_push = should_suppress_offline_push(
        offline_user_ids.len(),
        is_group,
        is_encrypted,
        &fields.content,
    );

    if suppress_offline_push {
        // Audit #451 abuse surface: counts only, no body or recipient IDs.
        tracing::info!(
            %sender_id,
            %conv_id,
            suppressed = offline_user_ids.len(),
            "at_here_suppressed_offline_push"
        );
    }

    if !offline_user_ids.is_empty() && !suppress_offline_push {
        spawn_push_notifications(
            state.pool.clone(),
            offline_user_ids,
            &fields.from_username,
            &fields.content,
            is_encrypted,
            conv_id,
            stored_id,
        );
    }
}
