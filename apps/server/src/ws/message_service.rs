//! Message send, fanout, and delivery logic.

use axum::extract::ws::Message as WsMessage;
use chrono::{DateTime, Utc};
use std::collections::HashMap;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;
use crate::ws::handler::{ServerMessage, send_error};
use crate::ws::typing_service::get_member_ids_cached;

pub(super) const MAX_MESSAGE_LENGTH: usize = 10_000;

/// Validate that the message content does not exceed the maximum length.
pub(super) fn validate_message_length(state: &AppState, sender_id: Uuid, content: &str) -> bool {
    if content.len() > MAX_MESSAGE_LENGTH {
        send_error(
            state,
            sender_id,
            &format!(
                "Message too long: {} characters (max {})",
                content.len(),
                MAX_MESSAGE_LENGTH
            ),
        );
        return false;
    }
    true
}

/// Look up conversation security, validate channel usage, and enforce
/// encryption on direct messages.  Returns the security row, conversation
/// kind, and resolved channel id on success.
pub(super) async fn validate_conversation_security(
    state: &AppState,
    sender_id: Uuid,
    conv_id: Uuid,
    channel_id: Option<Uuid>,
) -> Option<(
    db::messages::ConversationSecurityRow,
    Option<ConversationKind>,
    Option<Uuid>,
)> {
    let conv_security = match db::messages::get_conversation_security(&state.pool, conv_id).await {
        Ok(Some(row)) => row,
        Ok(None) => {
            send_error(state, sender_id, "Conversation not found");
            return None;
        }
        Err(_) => {
            send_error(state, sender_id, "Database error");
            return None;
        }
    };

    let conv_kind = ConversationKind::from_str_opt(&conv_security.kind);
    if conv_kind != Some(ConversationKind::Group) && channel_id.is_some() {
        send_error(
            state,
            sender_id,
            "channel_id is only valid for group conversations",
        );
        return None;
    }

    let resolved_channel_id =
        resolve_channel(state, sender_id, conv_id, channel_id, conv_kind).await?;

    if conv_kind == Some(ConversationKind::Direct) && !conv_security.is_encrypted {
        send_error(
            state,
            sender_id,
            "Direct messages must be end-to-end encrypted",
        );
        return None;
    }

    Some((conv_security, conv_kind, resolved_channel_id))
}

/// Recipient-scoped per-device ciphertexts as carried on the wire:
/// `recipient_user_id (UUID string) -> { device_id (i32 string) -> ciphertext }`.
/// Per-user device IDs collide across users, so the storage and fanout
/// addressing must include the recipient (#522). Conversion to typed
/// `(Uuid, i32)` happens at the storage/fanout boundaries; rows that fail to
/// parse are logged and skipped.
pub(super) type RecipientDeviceContents = HashMap<String, HashMap<String, String>>;

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
) {
    if !validate_message_length(state, sender_id, &content) {
        return;
    }

    let Some(conv_id) = resolve_conversation(state, sender_id, conversation_id, to_user_id).await
    else {
        return;
    };

    let Some((conv_security, _conv_kind, resolved_channel_id)) =
        validate_conversation_security(state, sender_id, conv_id, channel_id).await
    else {
        return;
    };

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
        &recipient_device_contents,
        ttl_seconds,
    )
    .await
    else {
        return;
    };

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
    };

    fanout_message(
        state,
        sender_id,
        sender_device_id,
        conv_id,
        &deliver,
        stored.id,
        conv_security.is_encrypted,
        recipient_device_contents,
    )
    .await;
}

/// Persist the message to the database, store per-device ciphertexts, send
/// a `message_sent` confirmation to the originating device, and relay the
/// message to the sender's other devices.  Returns the stored message row
/// on success, or `None` after sending an error to the client.
#[allow(clippy::too_many_arguments)]
pub(super) async fn store_and_confirm(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    conv_id: Uuid,
    resolved_channel_id: Option<Uuid>,
    content: &str,
    reply_to_id: Option<Uuid>,
    recipient_device_contents: &Option<RecipientDeviceContents>,
    ttl_seconds: Option<i64>,
) -> Option<db::messages::MessageRow> {
    // Resolve TTL: use per-message override first, then fall back to conversation setting.
    // Clamp to valid range: 5 seconds to 1 year. Reject non-positive values.
    let ttl_seconds = ttl_seconds.filter(|&s| (5..=31_536_000).contains(&s));
    let effective_ttl = if ttl_seconds.is_some() {
        ttl_seconds
    } else {
        db::messages::get_conversation_ttl(&state.pool, conv_id)
            .await
            .unwrap_or(None)
    };

    // Store message in DB. `RowNotFound` from `store_message` means the
    // requested `reply_to_id` does not refer to a message in this conversation
    // (cross-conversation reply, deleted parent, or non-existent id). Surface
    // a targeted error to the sender instead of a generic store failure. #519
    let stored = match db::messages::store_message(
        &state.pool,
        conv_id,
        resolved_channel_id,
        sender_id,
        content,
        reply_to_id,
        effective_ttl,
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
        Err(_) => {
            send_error(state, sender_id, "Failed to store message");
            return None;
        }
    };

    // Store per-device ciphertexts if present, scoped by recipient (#522).
    if let Some(rdc) = recipient_device_contents {
        let entries: Vec<(Uuid, i32, &str)> = rdc
            .iter()
            .filter_map(|(uid_str, devices)| {
                let recipient_id = Uuid::parse_str(uid_str).ok()?;
                Some((recipient_id, devices))
            })
            .flat_map(|(recipient_id, devices)| {
                devices.iter().filter_map(move |(did_str, ct)| {
                    let did = did_str.parse::<i32>().ok()?;
                    Some((recipient_id, did, ct.as_str()))
                })
            })
            .collect();
        if !entries.is_empty()
            && let Err(e) =
                db::messages::store_device_contents(&state.pool, stored.id, &entries).await
        {
            tracing::error!("Failed to store device contents: {e:?}");
        }
    }

    // Send confirmation to sender's device
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

    // Self-device delivery: notify sender's OTHER devices about outgoing message.
    // Only the sender's own slice of recipient_device_contents is relevant here.
    if let Some(rdc) = recipient_device_contents
        && let Some(self_devices) = rdc.get(&sender_id.to_string())
    {
        for (did_str, ciphertext) in self_devices {
            let Ok(did) = did_str.parse::<i32>() else {
                continue;
            };
            if did == sender_device_id {
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
                    .send_to_device(&sender_id, did, WsMessage::Text(json.into()));
            }
        }
    }

    Some(stored)
}

/// Resolve the target conversation from either an explicit conversation_id or a to_user_id.
/// Returns None and sends an error to the sender on failure.
pub(super) async fn resolve_conversation(
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

/// Resolve the target channel for a message.
/// Returns `Some(Some(channel_id))` for groups, `Some(None)` for DMs, `None` on error.
pub(super) async fn resolve_channel(
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
pub(super) async fn validate_explicit_channel(
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
pub(super) async fn resolve_default_text_channel(
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

/// Look up reply context (content and username) for a given reply_to_id,
/// scoped to the conversation the new message will live in. #519
/// Returns `None` (with a `warn!`) when the parent is missing, deleted,
/// or belongs to a different conversation.
pub(super) async fn lookup_reply_context(
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

/// Common fields extracted from a `ServerMessage::NewMessage` for per-device rewriting
/// and push notification content.
pub(super) struct NewMessageFields {
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
    fn extract(message: &ServerMessage) -> Option<Self> {
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

/// Pre-serialize per-device JSON messages once for each recipient to avoid
/// re-serializing the same message for every member in the fanout loop.
/// Outer key is `recipient_user_id`, inner is `device_id -> JSON` (#522).
pub(super) fn build_per_device_json(
    fields: &NewMessageFields,
    recipient_device_contents: &RecipientDeviceContents,
) -> HashMap<Uuid, Vec<(i32, String)>> {
    recipient_device_contents
        .iter()
        .filter_map(|(uid_str, devices)| {
            let recipient_id = Uuid::parse_str(uid_str).ok()?;
            let entries: Vec<(i32, String)> = devices
                .iter()
                .filter_map(|(did_str, ciphertext)| {
                    let did = did_str.parse::<i32>().ok()?;
                    let per_device_msg = ServerMessage::NewMessage {
                        message_id: fields.message_id,
                        from_user_id: fields.from_user_id,
                        from_device_id: fields.from_device_id,
                        from_username: fields.from_username.clone(),
                        conversation_id: fields.conversation_id,
                        channel_id: fields.channel_id,
                        content: ciphertext.clone(),
                        timestamp: fields.timestamp,
                        reply_to_id: fields.reply_to_id,
                        reply_to_content: fields.reply_to_content.clone(),
                        reply_to_username: fields.reply_to_username.clone(),
                        expires_at: fields.expires_at,
                    };
                    let json = serde_json::to_string(&per_device_msg).ok()?;
                    Some((did, json))
                })
                .collect();
            Some((recipient_id, entries))
        })
        .collect()
}

/// Deliver a message to a single member via per-device or legacy delivery.
/// Returns `true` if the member received the message on at least one device.
pub(super) fn deliver_to_member(
    hub: &crate::ws::hub::Hub,
    member_id: &Uuid,
    per_recipient_json: Option<&HashMap<Uuid, Vec<(i32, String)>>>,
    legacy_json: Option<&str>,
) -> bool {
    if let Some(by_recipient) = per_recipient_json
        && let Some(device_jsons) = by_recipient.get(member_id)
    {
        return device_jsons.iter().any(|(did, json)| {
            hub.send_to_device(member_id, *did, WsMessage::Text(json.clone().into()))
        });
    }
    if let Some(json) = legacy_json {
        hub.send_to_user(member_id, WsMessage::Text(json.to_owned().into()))
    } else {
        false
    }
}

/// Mark messages as delivered in the DB and send a delivery confirmation back to the sender.
pub(super) async fn send_delivery_confirmation(
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

/// Spawn a background task to send push notifications to offline users.
pub(super) fn spawn_push_notifications(
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

/// Fan out a message to all conversation members (except sender), with block filtering
/// and delivery tracking. Supports per-device ciphertext delivery for multi-device.
#[allow(clippy::too_many_arguments)]
pub(super) async fn fanout_message(
    state: &AppState,
    sender_id: Uuid,
    sender_device_id: i32,
    conv_id: Uuid,
    message: &ServerMessage,
    stored_id: Uuid,
    is_encrypted: bool,
    recipient_device_contents: Option<RecipientDeviceContents>,
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

    // Batch check which members have blocked the sender (single query instead of N+1)
    let blockers: Vec<Uuid> = db::contacts::get_blockers_of(&state.pool, &member_ids, sender_id)
        .await
        .unwrap_or_default();

    // Pre-serialize per-recipient device JSON messages and legacy fallback
    let per_recipient_json = recipient_device_contents
        .as_ref()
        .map(|rdc| build_per_device_json(&fields, rdc));
    let legacy_json = serde_json::to_string(message).ok();

    let mut any_delivered = false;
    let mut offline_user_ids = Vec::new();

    let eligible = member_ids
        .iter()
        .filter(|id| **id != sender_id && !blockers.contains(id));

    for member_id in eligible {
        let delivered = deliver_to_member(
            &state.hub,
            member_id,
            per_recipient_json.as_ref(),
            legacy_json.as_deref(),
        );
        if delivered {
            any_delivered = true;
        } else {
            offline_user_ids.push(*member_id);
        }
    }

    if any_delivered {
        send_delivery_confirmation(state, sender_id, sender_device_id, stored_id, conv_id).await;
    }

    if !offline_user_ids.is_empty() {
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

/// Deliver any messages that were stored while the user was offline, then mark
/// them delivered and notify the original senders.
///
/// For encrypted DMs, each device has its own ciphertext stored in
/// `message_device_contents`.  A single batch query fetches all per-device
/// ciphertexts for the reconnecting device; the canonical `content` column is
/// used as a fallback when no device-specific row exists (group messages,
/// unencrypted convs, or messages predating multi-device support).
pub(super) async fn deliver_undelivered_messages(state: &AppState, user_id: Uuid, device_id: i32) {
    let undelivered = match db::messages::get_undelivered(&state.pool, user_id).await {
        Ok(msgs) => msgs,
        Err(_) => return,
    };

    if undelivered.is_empty() {
        return;
    }

    let all_ids: Vec<Uuid> = undelivered.iter().map(|m| m.id).collect();

    // Batch-fetch all per-device ciphertexts in a single query to avoid N+1.
    let device_ct_map =
        db::messages::get_device_contents_batch(&state.pool, &all_ids, user_id, device_id)
            .await
            .unwrap_or_default();

    // Track only IDs that the hub actually accepted into the recipient's
    // outbound queue. Marking a message delivered without confirmed enqueue
    // loses it forever if the queue was full or the socket had just closed (#523).
    let mut delivered_ids: Vec<Uuid> = Vec::with_capacity(undelivered.len());
    let mut delivered_msgs: Vec<&db::messages::MessageWithSender> =
        Vec::with_capacity(undelivered.len());

    for msg in &undelivered {
        // Prefer device-specific ciphertext; fall back to canonical content.
        let content = device_ct_map
            .get(&msg.id)
            .cloned()
            .unwrap_or_else(|| msg.content.clone());

        let server_msg = ServerMessage::NewMessage {
            message_id: msg.id,
            from_user_id: msg.sender_id,
            from_device_id: None, // Offline delivery doesn't track sender device
            from_username: msg.sender_username.clone(),
            conversation_id: msg.conversation_id,
            channel_id: msg.channel_id,
            content,
            timestamp: msg.created_at,
            reply_to_id: msg.reply_to_id,
            reply_to_content: msg.reply_to_content.clone(),
            reply_to_username: msg.reply_to_username.clone(),
            expires_at: None, // Offline delivery: expiry already passed if expired
        };
        let Ok(json) = serde_json::to_string(&server_msg) else {
            continue;
        };
        let enqueued = state
            .hub
            .send_to_device(&user_id, device_id, WsMessage::Text(json.into()));
        if enqueued {
            delivered_ids.push(msg.id);
            delivered_msgs.push(msg);
        } else {
            tracing::warn!(
                message_id = %msg.id,
                user_id = %user_id,
                device_id = device_id,
                "replay: hub rejected message — leaving as undelivered for next reconnect"
            );
        }
    }

    if delivered_ids.is_empty() {
        return;
    }

    let _ = db::messages::mark_delivered(&state.pool, &delivered_ids).await;

    // Notify original senders that their messages were delivered
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
