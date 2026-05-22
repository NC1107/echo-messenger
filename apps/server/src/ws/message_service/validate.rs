//! Input-validation helpers for inbound messages.
//!
//! Covers:
//! - wire-frame shape check (`is_valid_ciphertext_shape`)
//! - content length guard (`validate_message_length`)
//! - per-conversation encryption enforcement (`validate_encrypted_payload`)
//! - conversation security + channel resolution (`validate_conversation_security`)

use std::collections::HashMap;
use uuid::Uuid;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;

use echo_core::signal::protocol::{
    NORMAL_HEADER_LEN as ECHO_NORMAL_HEADER_LEN, WIRE_INITIAL_V1 as ECHO_WIRE_INITIAL_V1,
    WIRE_INITIAL_V2 as ECHO_WIRE_INITIAL_V2, WIRE_MAGIC as ECHO_WIRE_MAGIC,
};

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;
use crate::ws::error::send_error;

use super::routing::resolve_channel;
use super::types::RecipientDeviceContents;

pub(in crate::ws::message_service) const MAX_MESSAGE_LENGTH: usize = 10_000;

/// Group-message wire prefix used by `group_crypto_service.dart` to
/// distinguish AES-GCM group envelopes (prefix + base64 payload) from the
/// 1:1 Signal Protocol wire formats. The colon is intentionally part of
/// the prefix and is NOT a valid base64 character, so a naive
/// `BASE64.decode(content)` on a group payload fails — this validator
/// must inspect the textual prefix BEFORE attempting any base64 decode.
///
/// `GRP1:` is shipping today. `GRP2:` is reserved for the design in
/// `docs/group-e2e-design/03-recommended-protocol.md` which adds per-
/// message Ed25519 sender signatures. Both prefixes are accepted here
/// so a future client rollout doesn't need a coordinated server flip.
pub(in crate::ws::message_service) const GROUP_WIRE_PREFIX_V1: &str = "GRP1:";
pub(in crate::ws::message_service) const GROUP_WIRE_PREFIX_V2: &str = "GRP2:";

// ── Wire-frame shape ────────────────────────────────────────────────────────

/// Validate that a payload is shaped like an Echo ciphertext wire frame.
/// We do NOT decrypt or otherwise validate authenticity here — this is a
/// belt-and-suspenders shape gate that prevents a malicious or buggy
/// client from storing/relaying plaintext on conversations marked
/// `is_encrypted = true`.
///
/// Accepts three shapes:
/// - **1:1 initial V1/V2** — base64 of `[0xEC, version] + ...`.
/// - **1:1 normal** — base64 whose first 4 LE bytes equal `header_len=40`.
/// - **Group GRP1: / GRP2:** — literal textual prefix followed by base64.
///   The group form is checked BEFORE base64 decoding because the `:`
///   character is not a valid base64 alphabet member.
pub(in crate::ws::message_service) fn is_valid_ciphertext_shape(payload: &str) -> bool {
    // Group wires carry a textual prefix that breaks naive base64 decode.
    // Strip the prefix and verify the remainder is non-empty + valid base64
    // with enough bytes for `nonce(12) || ct || tag(16)`.
    for prefix in [GROUP_WIRE_PREFIX_V1, GROUP_WIRE_PREFIX_V2] {
        if let Some(after_prefix) = payload.strip_prefix(prefix) {
            let Ok(bytes) = BASE64.decode(after_prefix.as_bytes()) else {
                return false;
            };
            // Minimum: 12-byte nonce + 16-byte AEAD tag = 28 bytes. A real
            // message will be longer, but we only gate the structural floor.
            return bytes.len() >= 28;
        }
    }

    // 1:1 wires are pure base64.
    let Ok(bytes) = BASE64.decode(payload.as_bytes()) else {
        return false;
    };

    // Initial-message wires (V1 / V2) start with the 0xEC magic byte plus
    // a known version. We require the keys+ratchet wire to follow but only
    // gate the prefix here; full structural validation lives in the crypto
    // layer.
    if bytes.len() >= 2
        && bytes[0] == ECHO_WIRE_MAGIC
        && (bytes[1] == ECHO_WIRE_INITIAL_V1 || bytes[1] == ECHO_WIRE_INITIAL_V2)
    {
        return true;
    }

    // Normal messages start with a u32 LE header_len of exactly 40.
    if bytes.len() >= 4 {
        let header_len = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        if header_len == ECHO_NORMAL_HEADER_LEN {
            return true;
        }
    }

    false
}

// ── Length ──────────────────────────────────────────────────────────────────

/// Validate that the message content is non-empty (after trimming) and
/// does not exceed the maximum length.  REST edit already rejects empty
/// strings; the WS path didn't, which let clients persist a whitespace-
/// only message that surfaced as a blank bubble in the timeline.
///
/// Trim-emptiness only applies to the *plaintext* path -- encrypted
/// conversations carry base64-encoded ciphertext that starts with magic
/// bytes (`0xEC 0x01/0x02` or a 4-byte LE header_len of 40), so the
/// canonical content is never empty there.  We still gate it through a
/// trim because base64 of a real ciphertext doesn't whitespace-out.
pub(in crate::ws::message_service) fn validate_message_length(
    state: &AppState,
    sender_id: Uuid,
    content: &str,
) -> bool {
    if content.trim().is_empty() {
        send_error(state, sender_id, "Content cannot be empty");
        return false;
    }
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

// ── Encrypted-payload gate ───────────────────────────────────────────────────

/// Error string surfaced to the sender on any ciphertext-shape rejection.
/// Kept as a single const so all rejection sites in
/// [`validate_encrypted_payload`] stay byte-for-byte identical and can be
/// grep'd as one symbol from logs / clients.
const ENCRYPTED_PAYLOAD_REQUIRED: &str = "Encrypted conversation requires ciphertext payload";

/// Send the canonical "requires ciphertext payload" error to `sender_id`.
fn send_payload_error(state: &AppState, sender_id: Uuid) {
    send_error(state, sender_id, ENCRYPTED_PAYLOAD_REQUIRED);
}

/// Reject an encrypted DM whose canonical `content` field is not ciphertext-shaped.
///
/// Returns `false` on rejection (error already sent to `sender_id`).
fn validate_dm_canonical_content(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Uuid,
    content: &str,
) -> bool {
    if !is_valid_ciphertext_shape(content) {
        tracing::warn!(
            conversation_id = %conversation_id,
            sender_id = %sender_id,
            "rejected encrypted DM: canonical content is not ciphertext-shaped"
        );
        send_payload_error(state, sender_id);
        return false;
    }
    true
}

/// Reject an encrypted DM whose `recipient_device_contents` map is absent or empty.
///
/// Returns `false` on rejection (error already sent to `sender_id`).
fn validate_dm_device_map_present<'a>(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Uuid,
    rdc: Option<&'a RecipientDeviceContents>,
) -> Option<&'a RecipientDeviceContents> {
    let Some(rdc) = rdc else {
        tracing::warn!(
            conversation_id = %conversation_id,
            sender_id = %sender_id,
            "rejected encrypted DM with no recipient_device_contents"
        );
        send_payload_error(state, sender_id);
        return None;
    };
    if rdc.is_empty() {
        tracing::warn!(
            conversation_id = %conversation_id,
            sender_id = %sender_id,
            "rejected encrypted DM with empty recipient_device_contents"
        );
        send_payload_error(state, sender_id);
        return None;
    }
    Some(rdc)
}

/// Reject an encrypted DM if any per-recipient device map is empty or
/// any individual per-device ciphertext is not shaped like a wire frame.
///
/// Returns `false` on the first violation (error already sent to `sender_id`).
fn validate_dm_per_device_ciphertexts(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Uuid,
    rdc: &HashMap<String, HashMap<String, String>>,
) -> bool {
    for (recipient, devices) in rdc.iter() {
        if devices.is_empty() {
            tracing::warn!(
                conversation_id = %conversation_id,
                sender_id = %sender_id,
                recipient = %recipient,
                "rejected encrypted DM: empty per-recipient device map"
            );
            send_payload_error(state, sender_id);
            return false;
        }
        for (device_id, ciphertext) in devices.iter() {
            if !is_valid_ciphertext_shape(ciphertext) {
                tracing::warn!(
                    conversation_id = %conversation_id,
                    sender_id = %sender_id,
                    recipient = %recipient,
                    device_id = %device_id,
                    "rejected encrypted DM: per-device payload is not ciphertext-shaped"
                );
                send_payload_error(state, sender_id);
                return false;
            }
        }
    }
    true
}

/// Reject inbound messages on encrypted conversations whose payload isn't
/// shaped like an Echo ciphertext wire frame.
///
/// - Direct (DM): `recipient_device_contents` MUST be non-empty and every
///   per-device ciphertext MUST pass `is_valid_ciphertext_shape`.
/// - Group: the canonical `content` field carries the group-key envelope
///   wire and MUST pass `is_valid_ciphertext_shape`.
///
/// Returns `true` when the payload is acceptable. On rejection the helper
/// emits a `tracing::warn!` (so we can observe attempts) and sends a
/// targeted error frame back to the sender.
pub(in crate::ws::message_service) fn validate_encrypted_payload(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Uuid,
    conv_kind: Option<ConversationKind>,
    content: &str,
    recipient_device_contents: Option<&RecipientDeviceContents>,
) -> bool {
    match conv_kind {
        Some(ConversationKind::Direct) => {
            // The canonical content field is persisted and relayed in
            // NewMessage events, so it must be ciphertext-shaped — otherwise
            // a client could pass valid recipient_device_contents while
            // smuggling plaintext in `content`.
            if !validate_dm_canonical_content(state, sender_id, conversation_id, content) {
                return false;
            }
            let Some(rdc) = validate_dm_device_map_present(
                state,
                sender_id,
                conversation_id,
                recipient_device_contents,
            ) else {
                return false;
            };
            validate_dm_per_device_ciphertexts(state, sender_id, conversation_id, rdc)
        }
        Some(ConversationKind::Group) => {
            if !is_valid_ciphertext_shape(content) {
                tracing::warn!(
                    conversation_id = %conversation_id,
                    sender_id = %sender_id,
                    "rejected encrypted group message: content is not ciphertext-shaped"
                );
                send_payload_error(state, sender_id);
                return false;
            }
            true
        }
        // Unknown / unrecognised kind: leave existing flow to handle errors.
        None => true,
    }
}

// ── Encrypted-group sender membership (Phase 1.5, audit P1-2) ───────────────

/// Structured rejection code used by the encrypted-group sender-membership
/// check. Kept as a const so test assertions and log greps can match a
/// single literal regardless of any surrounding human-readable wording.
///
/// Surfaced verbatim in the WS `error` frame sent back to the sender — see
/// [`enforce_group_sender_membership`].
pub(in crate::ws::message_service) const SENDER_NOT_MEMBER_CODE: &str = "sender-not-member";

/// Belt-and-suspenders gate for the encrypted-group send path: re-verify
/// that the JWT-authenticated sender is currently an active member of the
/// target conversation before the message is persisted or fanned out.
///
/// Why this exists even though [`super::routing::resolve_conversation`]
/// already calls `is_member`:
///
/// - It runs on the **encrypted-group branch only** (other kinds are
///   either DM contact-gated or plaintext groups, which are out of scope
///   for the Phase 1.5 design — see
///   `docs/group-e2e-design/04-migration-plan.md` §"Phase 1.5").
/// - It emits a **structured `sender-not-member` code** so kicked-member
///   send attempts are observable as a single signal in logs / metrics
///   without grepping a free-form error string.
/// - It defends in depth: any future refactor that bypasses
///   `resolve_conversation` (e.g. a new entry point that already has the
///   conversation id resolved) still has to clear this gate before a
///   ciphertext can be relayed to surviving members.
///
/// Returns `true` when the sender is a current member.  On rejection the
/// helper emits a `tracing::warn!` and sends an error frame to the sender
/// whose `message` is exactly [`SENDER_NOT_MEMBER_CODE`].
pub(in crate::ws::message_service) async fn enforce_group_sender_membership(
    state: &AppState,
    sender_id: Uuid,
    conversation_id: Uuid,
) -> bool {
    match db::groups::is_member(&state.pool, conversation_id, sender_id).await {
        Ok(true) => true,
        Ok(false) => {
            tracing::warn!(
                conversation_id = %conversation_id,
                sender_id = %sender_id,
                code = SENDER_NOT_MEMBER_CODE,
                "rejected encrypted-group send: sender is not a current member",
            );
            send_error(state, sender_id, SENDER_NOT_MEMBER_CODE);
            false
        }
        Err(e) => {
            tracing::warn!(
                conversation_id = %conversation_id,
                sender_id = %sender_id,
                error = ?e,
                "db error checking sender membership on encrypted group send",
            );
            send_error(state, sender_id, "Database error");
            false
        }
    }
}

// ── Conversation security ────────────────────────────────────────────────────

/// Look up conversation security, validate channel usage, and enforce
/// encryption on direct messages.  Returns the security row, conversation
/// kind, and resolved channel id on success.
pub(in crate::ws::message_service) async fn validate_conversation_security(
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

// ── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // Helper: encode arbitrary bytes as standard base64.
    fn b64(bytes: &[u8]) -> String {
        BASE64.encode(bytes)
    }

    // ── is_valid_ciphertext_shape ─────────────────────────────────────────────

    #[test]
    fn shape_v1_initial_accepted() {
        // [0xEC, 0x01] + some payload bytes
        let payload = b64(&[0xEC, 0x01, 0x00, 0x01, 0x02, 0x03]);
        assert!(is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_v2_initial_accepted() {
        // [0xEC, 0x02] + some payload bytes
        let payload = b64(&[0xEC, 0x02, 0xAA, 0xBB]);
        assert!(is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_normal_message_accepted() {
        // u32 LE header_len == 40 (ECHO_NORMAL_HEADER_LEN)
        let mut bytes = vec![40u8, 0, 0, 0]; // 40 as little-endian u32
        bytes.extend_from_slice(&[0u8; 40]); // header
        bytes.extend_from_slice(&[0u8; 12]); // nonce
        bytes.extend_from_slice(&[0u8; 16]); // ciphertext + tag
        let payload = b64(&bytes);
        assert!(is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_invalid_base64_rejected() {
        assert!(!is_valid_ciphertext_shape("not!valid!base64!!!!!"));
    }

    #[test]
    fn shape_wrong_magic_byte_rejected() {
        // First byte is 0xAB, not 0xEC
        let payload = b64(&[0xAB, 0x01, 0x00, 0x00]);
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_too_short_rejected() {
        // Single byte — can't match any branch
        let payload = b64(&[0xEC]);
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_empty_rejected() {
        let payload = b64(&[]);
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_normal_wrong_header_len_rejected() {
        // 4-byte LE value of 41 — not 40
        let mut bytes = vec![41u8, 0, 0, 0];
        bytes.extend_from_slice(&[0u8; 40]);
        let payload = b64(&bytes);
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_plaintext_rejected() {
        // A realistic ASCII message that should not pass the gate
        let payload = b64(b"Hello, world!");
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    // ── Group wire-prefix awareness (#591) ───────────────────────────────────

    /// Group AES-GCM envelope: 12-byte nonce + ciphertext + 16-byte tag,
    /// minimum 28 bytes when ct is empty. We accept anything ≥ 28 bytes
    /// of decoded payload after the prefix.
    fn group_envelope(ct_len: usize) -> String {
        let total = 12 + ct_len + 16;
        b64(&vec![0u8; total])
    }

    #[test]
    fn shape_grp1_prefix_accepted() {
        // Real client emits `GRP1:` + base64(nonce(12) || ct || tag(16)).
        // Smallest valid payload: ct is empty -> 28 bytes total.
        let payload = format!("{GROUP_WIRE_PREFIX_V1}{}", group_envelope(0));
        assert!(is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_grp2_prefix_accepted() {
        // Future GRP2 wires also flow through this validator without a
        // coordinated server flip. Payload after the prefix is base64 of
        // version(1) + nonce(12) + ct + tag(16) + sig(64); the structural
        // floor here is just "≥ 28 bytes of decoded payload".
        let payload = format!("{GROUP_WIRE_PREFIX_V2}{}", group_envelope(64));
        assert!(is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_grp1_prefix_with_invalid_base64_rejected() {
        // Prefix is right, body is junk that doesn't decode.
        let payload = format!("{GROUP_WIRE_PREFIX_V1}not!valid!base64!");
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_grp1_prefix_with_too_short_payload_rejected() {
        // Decoded body shorter than the 28-byte AEAD floor (nonce+tag).
        let payload = format!("{GROUP_WIRE_PREFIX_V1}{}", b64(&[0u8; 16]));
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    #[test]
    fn shape_grp1_prefix_empty_payload_rejected() {
        // Just the prefix with no base64 body.
        assert!(!is_valid_ciphertext_shape(GROUP_WIRE_PREFIX_V1));
    }

    #[test]
    fn shape_grp_lowercase_prefix_rejected() {
        // Prefix is case-sensitive — a `grp1:` would not match.
        let payload = format!("grp1:{}", group_envelope(0));
        assert!(!is_valid_ciphertext_shape(&payload));
    }

    /// Regression test for the audit's findings doc: prior to the GRP-prefix
    /// fix, naïve base64-decoding a `GRP1:` payload would fail because `:`
    /// is not a valid base64 alphabet member — meaning every encrypted-group
    /// message hitting this validator got silently dropped. This test
    /// ensures we never regress that path. (#591 audit follow-up.)
    #[test]
    fn shape_regression_grp1_was_silently_failing_pre_fix() {
        let payload = format!("{GROUP_WIRE_PREFIX_V1}{}", group_envelope(0));
        // Documented expectation: accepted under the fixed validator.
        assert!(
            is_valid_ciphertext_shape(&payload),
            "GRP1-prefixed group ciphertext must be accepted",
        );
        // Sanity-check the failure mode the fix corrects: dropping the prefix
        // recovers a base64-decodable payload, but the FULL string with the
        // `:` does not.
        assert!(BASE64.decode(payload.as_bytes()).is_err());
    }
}
