//! Shared data types for message send, storage, and fanout.

use std::collections::HashMap;
use uuid::Uuid;

/// Recipient-scoped per-device ciphertexts as carried on the wire:
/// `recipient_user_id (UUID string) -> { device_id (i32 string) -> ciphertext }`.
/// Per-user device IDs collide across users, so the storage and fanout
/// addressing must include the recipient. Conversion to typed
/// `(Uuid, i32)` happens at the deserialization boundary (see
/// [`ParsedRecipientDeviceContents::from_wire`]) so downstream code doesn't
/// re-parse the same UUID + i32 fields once per fanout stage (#834
/// finding 15).
pub(in crate::ws::message_service) type RecipientDeviceContents =
    HashMap<String, HashMap<String, String>>;

/// Pre-parsed form of [`RecipientDeviceContents`]: UUID + i32 fields are
/// parsed once at the entry boundary so the storage, revoked-filter,
/// per-device JSON build, and self-device delivery paths all read typed
/// values instead of re-parsing strings (#834 finding 15).
///
/// Rows that fail to parse (malformed UUID or non-integer device id) are
/// logged once and dropped here — historically each downstream stage
/// silently skipped them via `Uuid::parse_str(...).ok()?`, which made it
/// impossible to tell from logs whether a client was sending garbage.
#[derive(Debug, Default, Clone)]
pub(in crate::ws::message_service) struct ParsedRecipientDeviceContents {
    pub by_user: HashMap<Uuid, HashMap<i32, String>>,
}

impl ParsedRecipientDeviceContents {
    /// Parse the wire-shape map once. Returns `None` if the input is `None`;
    /// otherwise always returns `Some` (possibly empty if every row was
    /// malformed). The caller keeps the original `RecipientDeviceContents`
    /// usage where the wire form is still needed (e.g. `validate_encrypted_payload`
    /// reports `recipient`/`device_id` strings in its `tracing::warn!` context).
    pub fn from_wire(rdc: &RecipientDeviceContents) -> Self {
        let mut by_user: HashMap<Uuid, HashMap<i32, String>> = HashMap::with_capacity(rdc.len());
        for (uid_str, devices) in rdc {
            let Ok(uid) = Uuid::parse_str(uid_str) else {
                tracing::debug!(uid = %uid_str, "dropped recipient_device_contents row: bad uuid");
                continue;
            };
            let mut by_device: HashMap<i32, String> = HashMap::with_capacity(devices.len());
            for (did_str, ciphertext) in devices {
                let Ok(did) = did_str.parse::<i32>() else {
                    tracing::debug!(
                        uid = %uid_str,
                        did = %did_str,
                        "dropped recipient_device_contents row: bad device id"
                    );
                    continue;
                };
                by_device.insert(did, ciphertext.clone());
            }
            by_user.insert(uid, by_device);
        }
        Self { by_user }
    }

    pub fn recipient_ids(&self) -> Vec<Uuid> {
        self.by_user.keys().copied().collect()
    }
}
