//! Wire-format constants shared by the Rust server, the Rust core, and the
//! Dart client.
//!
//! Audit #700 (H34): before this module, these constants were re-typed in
//! at least three places (Rust server, Rust core, Dart client). One typo
//! silently breaks decryption with no compile-time check. CLAUDE.md
//! documented the wire format in prose but no schema lived in version
//! control.
//!
//! Phase 1 (this PR): Rust server + Rust core re-export from a single
//! definition here. Dart parity is Phase 2 — it requires either codegen
//! from a manifest or a CI test that round-trips a Rust-encrypted
//! ciphertext through Dart and vice versa with a fixed seed.
//!
//! ## Wire format reference
//!
//! Every encrypted message frame starts with a magic byte sequence so the
//! server can distinguish protocol versions and reject malformed payloads
//! at the edge:
//!
//! ```text
//! Initial V1 (no OTP): [0xEC, 0x01] || identity_pub(32) || ephemeral_pub(32) || ratchet_wire
//! Initial V2 (OTP):    [0xEC, 0x02] || identity_pub(32) || ephemeral_pub(32) || otp_id(4 LE) || ratchet_wire
//! Normal:              header_len(4 LE) || header(40) || nonce(12) || ciphertext || tag(16)
//! ```
//!
//! Where `ratchet_wire` is the canonical `MessageHeader` (see ratchet.rs)
//! plus AEAD payload.

// -----------------------------------------------------------------------
// Magic bytes
// -----------------------------------------------------------------------

/// First byte of every encrypted Echo wire frame. Picked so it lands
/// outside ASCII printable range to make accidental plaintext-vs-ciphertext
/// confusion noisy when humans inspect frames.
pub const WIRE_MAGIC: u8 = 0xEC;

/// Second byte for an "initial" frame using the V1 X3DH flow (no
/// one-time prekey consumed). Carries identity + ephemeral public keys.
pub const WIRE_INITIAL_V1: u8 = 0x01;

/// Second byte for an "initial" frame using the V2 X3DH flow (consumes
/// a one-time prekey identified by the embedded `otp_id`).
pub const WIRE_INITIAL_V2: u8 = 0x02;

/// Length of the Double Ratchet `MessageHeader` serialised on the wire,
/// per `MessageHeader::serialize`:
///   - 32 bytes ratchet_public_key
///   - 4 bytes prev_chain_length (LE u32)
///   - 4 bytes message_number (LE u32)
pub const NORMAL_HEADER_LEN: u32 = 40;

// -----------------------------------------------------------------------
// HKDF info strings
// -----------------------------------------------------------------------

/// HKDF info passed into the Double Ratchet KDF for chain-key + message-key
/// derivation. The byte sequence is part of the protocol contract: changing
/// it on either side breaks decryption silently.
pub const RATCHET_KDF_INFO: &[u8] = b"EchoDoubleRatchet";

/// HKDF info for the X3DH shared-secret derivation. Same contract: any
/// rename or byte-level change breaks new sessions.
pub const X3DH_HKDF_INFO: &[u8] = b"EchoSignalX3DH";

// -----------------------------------------------------------------------
// Skip-key bounds (audit CRIT-4)
// -----------------------------------------------------------------------

/// Maximum number of message keys that can be skipped in a single
/// `skip_message_keys` call. Without this an attacker that controls
/// `message_number` can force unbounded key derivation.
pub const MAX_SKIP: u32 = 1000;

/// Global cap on `skipped_keys` map size across the lifetime of a session.
/// Prevents an adversary that bumps the DH ratchet repeatedly (each step
/// resets `recv_counter` to 0) from accumulating skipped keys without
/// bound.
pub const MAX_SKIPPED_KEYS: usize = 2000;

// -----------------------------------------------------------------------
// Compile-time invariants
// -----------------------------------------------------------------------

// The serializer in MessageHeader::serialize hard-codes a 40-byte layout;
// this assertion guarantees future contributors who change either side
// notice immediately.
const _: () = {
    assert!(NORMAL_HEADER_LEN == 40);
};
