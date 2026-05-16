//! WebSocket wire protocol: client-bound and server-bound message envelopes.
//!
//! `ClientMessage` is the inbound (server-receives) envelope; `ServerMessage`
//! is the outbound (server-sends) envelope. Both are `serde(tag = "type")`
//! adjacently-tagged enums so the JSON wire format remains stable.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(tag = "type")]
pub(super) enum ClientMessage {
    #[serde(rename = "send_message")]
    SendMessage {
        conversation_id: Option<Uuid>,
        channel_id: Option<Uuid>,
        to_user_id: Option<Uuid>,
        content: String,
        reply_to_id: Option<Uuid>,
        /// Recipient-scoped per-device ciphertexts:
        /// `recipient_user_id (UUID string) -> { device_id (i32 string) -> base64 ciphertext }`.
        /// JSON object keys are strings on the wire; conversion to typed
        /// `(Uuid, i32)` happens at the storage and fanout boundaries. Recipient
        /// scoping is required because per-user device IDs collide across users.
        #[serde(default)]
        recipient_device_contents: Option<HashMap<String, HashMap<String, String>>>,
        /// Optional TTL in seconds. When Some, overrides the conversation-level
        /// disappearing-messages setting for this specific message.
        #[serde(default)]
        ttl_seconds: Option<i64>,
    },
    #[serde(rename = "typing")]
    Typing {
        conversation_id: Uuid,
        channel_id: Option<Uuid>,
    },
    #[serde(rename = "read_receipt")]
    ReadReceipt { conversation_id: Uuid },
    #[serde(rename = "voice_signal")]
    VoiceSignal {
        conversation_id: Uuid,
        channel_id: Uuid,
        to_user_id: Uuid,
        signal: serde_json::Value,
    },
    #[serde(rename = "key_reset")]
    KeyReset { conversation_id: Uuid },
    #[serde(rename = "call_started")]
    CallStarted { conversation_id: Uuid },
    /// Voice-lounge canvas event.  Relayed to all conversation members and
    /// persisted for strokes/images (avatar moves are ephemeral).
    ///
    /// `kind` is one of: "stroke", "clear", "image_add", "image_move",
    ///                    "image_remove", "avatar_move"
    #[serde(rename = "canvas_event")]
    CanvasEvent {
        channel_id: Uuid,
        kind: String,
        payload: serde_json::Value,
    },
}

#[derive(Serialize, Clone)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "new_message")]
    NewMessage {
        message_id: Uuid,
        from_user_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        from_device_id: Option<i32>,
        from_username: String,
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        content: String,
        timestamp: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_id: Option<Uuid>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_username: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        expires_at: Option<DateTime<Utc>>,
        /// Set to `true` when the server cannot deliver per-device ciphertext
        /// for this recipient (e.g. offline-replay where the message predates
        /// multi-device fanout, or no row exists for this device). The client
        /// should render an undecryptable placeholder rather than attempting
        /// to decrypt foreign ciphertext.
        #[serde(skip_serializing_if = "Option::is_none")]
        undecryptable: Option<bool>,
    },
    /// Sent to the sender's OTHER devices so they see outgoing messages.
    #[serde(rename = "self_message")]
    SelfMessage {
        message_id: Uuid,
        from_device_id: i32,
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        content: String,
        timestamp: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to_id: Option<Uuid>,
    },
    #[serde(rename = "message_sent")]
    MessageSent {
        message_id: Uuid,
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        timestamp: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        expires_at: Option<DateTime<Utc>>,
    },
    #[serde(rename = "delivered")]
    Delivered {
        message_id: Uuid,
        conversation_id: Uuid,
    },
    #[serde(rename = "typing")]
    Typing {
        conversation_id: Uuid,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<Uuid>,
        user_id: Uuid,
        from_username: String,
    },
    #[serde(rename = "read_receipt")]
    ReadReceipt {
        conversation_id: Uuid,
        user_id: Uuid,
    },
    #[serde(rename = "error")]
    Error { message: String },
    #[serde(rename = "voice_signal")]
    VoiceSignal {
        conversation_id: Uuid,
        channel_id: Uuid,
        from_user_id: Uuid,
        signal: serde_json::Value,
    },
    #[serde(rename = "key_reset")]
    KeyReset {
        from_user_id: Uuid,
        from_username: String,
        conversation_id: Uuid,
    },
    #[serde(rename = "call_started")]
    CallStarted {
        from_user_id: Uuid,
        from_username: String,
        conversation_id: Uuid,
    },
    /// Sent to all conversation members when a disappearing message is deleted.
    #[serde(rename = "message_expired")]
    MessageExpired {
        message_id: Uuid,
        conversation_id: Uuid,
    },
    /// Sent to all sessions of a user when one of their devices is revoked.
    /// The receiving client should log out if `device_id` matches its own.
    #[serde(rename = "device_revoked")]
    DeviceRevoked { device_id: i32 },
    /// Voice-lounge canvas event relayed to all conversation members.
    #[serde(rename = "canvas_event")]
    CanvasEvent {
        channel_id: Uuid,
        from_user_id: Uuid,
        kind: String,
        payload: serde_json::Value,
    },
}
