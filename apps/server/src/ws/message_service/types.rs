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

// ── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_wire(entries: &[(&str, &[(&str, &str)])]) -> RecipientDeviceContents {
        entries
            .iter()
            .map(|(uid, devices)| {
                let dev_map: HashMap<String, String> = devices
                    .iter()
                    .map(|(did, ct)| (did.to_string(), ct.to_string()))
                    .collect();
                (uid.to_string(), dev_map)
            })
            .collect()
    }

    #[test]
    fn from_wire_valid_round_trip() {
        let uid = Uuid::new_v4();
        let wire = make_wire(&[(&uid.to_string(), &[("1", "ct_a"), ("2", "ct_b")])]);

        let parsed = ParsedRecipientDeviceContents::from_wire(&wire);

        let devices = parsed.by_user.get(&uid).expect("uid should be present");
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[&1], "ct_a");
        assert_eq!(devices[&2], "ct_b");
    }

    #[test]
    fn from_wire_malformed_uuid_is_silently_dropped() {
        let wire = make_wire(&[("not-a-valid-uuid", &[("0", "some_ct")])]);
        let parsed = ParsedRecipientDeviceContents::from_wire(&wire);
        // The bad entry must be dropped; by_user stays empty.
        assert!(
            parsed.by_user.is_empty(),
            "malformed UUID row must be dropped"
        );
    }

    #[test]
    fn from_wire_malformed_device_id_is_dropped() {
        let uid = Uuid::new_v4();
        let wire = make_wire(&[(&uid.to_string(), &[("not_an_int", "ct_x"), ("3", "ct_y")])]);
        let parsed = ParsedRecipientDeviceContents::from_wire(&wire);

        let devices = parsed.by_user.get(&uid).expect("uid should be present");
        // "not_an_int" device dropped; device 3 survives.
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[&3], "ct_y");
    }

    #[test]
    fn from_wire_empty_input_produces_empty_result() {
        let wire: RecipientDeviceContents = HashMap::new();
        let parsed = ParsedRecipientDeviceContents::from_wire(&wire);
        assert!(parsed.by_user.is_empty());
        assert!(parsed.recipient_ids().is_empty());
    }

    #[test]
    fn recipient_ids_returns_all_valid_uuids() {
        let uid_a = Uuid::new_v4();
        let uid_b = Uuid::new_v4();
        let wire = make_wire(&[
            (&uid_a.to_string(), &[("0", "ct_a")]),
            (&uid_b.to_string(), &[("1", "ct_b")]),
        ]);
        let parsed = ParsedRecipientDeviceContents::from_wire(&wire);
        let mut ids = parsed.recipient_ids();
        ids.sort();
        let mut expected = vec![uid_a, uid_b];
        expected.sort();
        assert_eq!(ids, expected);
    }
}
