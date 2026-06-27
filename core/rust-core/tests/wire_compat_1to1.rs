//! Cross-implementation wire-compat test for the 1:1 X3DH + Double-Ratchet
//! primitives (audit P2-2).
//!
//! Loads golden vectors from the repo-root `tests/wire_compat/1to1/` directory
//! and asserts the Rust reference (`core/rust-core/src/signal/`) agrees with the
//! recorded expected bytes. The Dart production impl loads the SAME files in
//! `apps/client/test/services/signal_1to1_wire_compat_test.dart` and runs the
//! same assertions, so a divergence in either implementation fails a test.
//!
//! Covered surfaces (the deterministic, byte-level pieces both impls must
//! agree on — the GRP2 harness covers the group wire, this covers 1:1):
//!  - **X3DH `respond`** shared-secret derivation: the DH operation order +
//!    HKDF label (`EchoSignalX3DH`) that, if they drifted between Rust and
//!    Dart, would silently corrupt every 1:1 session.
//!  - **`MessageHeader`** 40-byte wire layout: `ratchet_pub(32) ||
//!    prev_chain_length(4 LE) || message_number(4 LE)`.
//!
//! `respond` (unlike `initiate`, which self-generates a random ephemeral) is
//! fully deterministic, so it can be pinned. The full end-to-end ratchet
//! message + Initial-V2 outer frame need a frozen-bytes generation step and are
//! tracked as a follow-up in `TECHNICAL_DEBT.md`.
//!
//! Do NOT fudge a golden to make a test pass — a mismatch is a real find.
//! See `tests/wire_compat/README.md`.

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use echo_core::signal::keys::IdentityKeyPair;
use echo_core::signal::ratchet::MessageHeader;
use echo_core::signal::x3dh::respond;
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
struct Vector {
    name: String,
    kind: String,
    // --- message_header ---
    ratchet_public_key_b64: Option<String>,
    prev_chain_length: Option<u32>,
    message_number: Option<u32>,
    expected_header_b64: Option<String>,
    // --- x3dh_respond (all keys pinned as private bytes; publics derived) ---
    bob_identity_private_b64: Option<String>,
    signing_seed_b64: Option<String>,
    bob_signed_prekey_private_b64: Option<String>,
    bob_one_time_prekey_private_b64: Option<String>,
    alice_identity_private_b64: Option<String>,
    alice_ephemeral_private_b64: Option<String>,
    expected_shared_secret_b64: Option<String>,
}

fn vectors_dir() -> PathBuf {
    // CARGO_MANIFEST_DIR points at core/rust-core; the vectors live at the
    // workspace root under tests/wire_compat/1to1.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("workspace root above core/rust-core")
        .join("tests")
        .join("wire_compat")
        .join("1to1")
}

fn load_vectors() -> Vec<Vector> {
    let dir = vectors_dir();
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("read vectors dir {}: {e}", dir.display()))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    paths.sort();
    paths
        .into_iter()
        .map(|p| {
            let raw = std::fs::read_to_string(&p).expect("read vector");
            serde_json::from_str(&raw).unwrap_or_else(|e| panic!("parse {}: {e}", p.display()))
        })
        .collect()
}

fn b64d(s: &str) -> Vec<u8> {
    B64.decode(s).expect("valid base64")
}

fn arr32(bytes: &[u8]) -> [u8; 32] {
    let mut a = [0u8; 32];
    a.copy_from_slice(bytes);
    a
}

/// Build an `IdentityKeyPair` from a pinned X25519 private + Ed25519 seed.
/// (`deserialize` expects x25519_private(32) || ed25519_seed(32).)
fn keypair_from(priv_b64: &str, seed_b64: &str) -> IdentityKeyPair {
    let mut bytes = Vec::with_capacity(64);
    bytes.extend_from_slice(&b64d(priv_b64));
    bytes.extend_from_slice(&b64d(seed_b64));
    IdentityKeyPair::deserialize(&bytes).expect("deserialize identity keypair")
}

#[test]
fn message_header_vectors_match() {
    let mut checked = 0;
    for v in load_vectors() {
        if v.kind != "message_header" {
            continue;
        }
        let header = MessageHeader {
            ratchet_public_key: arr32(&b64d(v.ratchet_public_key_b64.as_ref().unwrap())),
            prev_chain_length: v.prev_chain_length.unwrap(),
            message_number: v.message_number.unwrap(),
        };
        let expected = b64d(v.expected_header_b64.as_ref().unwrap());
        assert_eq!(
            header.serialize(),
            expected,
            "MessageHeader serialize mismatch in vector {}",
            v.name
        );
        // Round-trip: the recorded bytes must parse back to the same header.
        let parsed = MessageHeader::deserialize(&expected)
            .unwrap_or_else(|e| panic!("deserialize {} failed: {e:?}", v.name));
        assert_eq!(
            parsed, header,
            "MessageHeader deserialize mismatch in {}",
            v.name
        );
        checked += 1;
    }
    assert!(checked > 0, "no message_header vectors found");
}

#[test]
fn x3dh_respond_vectors_match() {
    let mut checked = 0;
    for v in load_vectors() {
        if v.kind != "x3dh_respond" {
            continue;
        }
        let bob_identity = keypair_from(
            v.bob_identity_private_b64.as_ref().unwrap(),
            v.signing_seed_b64.as_ref().unwrap(),
        );
        // signed-prekey / one-time-prekey only need their X25519 private; the
        // signing seed is irrelevant to `respond`, so reuse the same seed.
        let seed = v.signing_seed_b64.as_ref().unwrap();
        let bob_spk = keypair_from(v.bob_signed_prekey_private_b64.as_ref().unwrap(), seed);
        let bob_otp = v
            .bob_one_time_prekey_private_b64
            .as_ref()
            .map(|p| keypair_from(p, seed));
        // Alice's identity/ephemeral publics derived from her pinned privates
        // (both impls derive the same X25519 public per RFC 7748).
        let alice_identity = keypair_from(v.alice_identity_private_b64.as_ref().unwrap(), seed);
        let alice_ephemeral = keypair_from(v.alice_ephemeral_private_b64.as_ref().unwrap(), seed);

        let secret = respond(
            &bob_identity,
            &bob_spk.private,
            bob_otp.as_ref().map(|k| &k.private),
            &alice_identity.public,
            &alice_ephemeral.public,
        )
        .unwrap_or_else(|e| panic!("respond failed for {}: {e:?}", v.name));

        let expected = v.expected_shared_secret_b64.as_ref().unwrap();
        if expected == "GENERATE" {
            // One-time generation pass: print the value to bake into the JSON.
            eprintln!(
                "GENERATE {} expected_shared_secret_b64 = {}",
                v.name,
                B64.encode(secret)
            );
            continue;
        }
        assert_eq!(
            B64.encode(secret),
            *expected,
            "X3DH respond shared-secret mismatch in vector {} \
             (Rust reference vs recorded golden — a real cross-impl divergence)",
            v.name
        );
        checked += 1;
    }
    // During generation `checked` stays 0; once baked it must assert at least one.
    if !load_vectors()
        .iter()
        .any(|v| v.expected_shared_secret_b64.as_deref() == Some("GENERATE"))
    {
        assert!(checked > 0, "no x3dh_respond vectors asserted");
    }
}
