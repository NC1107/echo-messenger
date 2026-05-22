//! Cross-implementation wire-compat test for the GRP2 group wire format.
//!
//! Loads golden vectors from the repo-root `tests/wire_compat/vectors/`
//! directory, runs each through the Rust reference packer + unpacker, and
//! asserts byte-for-byte agreement with the expected output recorded in
//! the JSON. The Dart side (in `apps/client/test/services/
//! group_crypto_wire_compat_test.dart`) loads the SAME files and runs
//! the same assertions through the Dart production impl.
//!
//! If a vector fails on either side, treat it as a real find: do NOT
//! fudge the golden to make tests pass. See `tests/wire_compat/README.md`.

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use echo_core::signal::grp2::{Grp2PackInput, Grp2UnpackInput, pack_grp2, unpack_grp2};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
struct Vector {
    name: String,
    description: String,
    /// Base64 of the 32-byte AES-256 group key.
    group_key_b64: String,
    /// Base64 of the 16-byte raw conversation UUID.
    conversation_id_b64: String,
    /// Base64 of the 16-byte raw message UUID.
    message_id_b64: String,
    /// Base64 of the 12-byte AES-GCM nonce. Pinned for determinism.
    nonce_b64: String,
    /// Base64 of the 32-byte Ed25519 signing-key seed. Pinned.
    signing_seed_b64: String,
    /// Base64 of the 32-byte Ed25519 verifying (public) key derived
    /// from the seed. Carried explicitly so the Dart side can verify
    /// without re-deriving (cross-impl Ed25519 seed handling must agree
    /// but the asymmetric assertion is more useful split out).
    verify_key_b64: String,
    /// UTF-8 plaintext that will be encrypted.
    plaintext_utf8: String,
    /// Expected wire including the `GRP2:` prefix.
    expected_wire_with_prefix: String,
    /// Expected Ed25519 signature (base64 of 64 bytes).
    expected_signature_b64: String,
}

fn vectors_dir() -> PathBuf {
    // CARGO_MANIFEST_DIR points at core/rust-core.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(Path::parent)
        .expect("workspace root above core/rust-core")
        .join("tests")
        .join("wire_compat")
        .join("vectors")
}

fn load_vectors() -> Vec<Vector> {
    let dir = vectors_dir();
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("read_dir({}): {e}", dir.display()))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("json"))
        .collect();
    paths.sort();
    paths
        .into_iter()
        .map(|p| {
            let s =
                std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()));
            serde_json::from_str(&s).unwrap_or_else(|e| panic!("parse {}: {e}", p.display()))
        })
        .collect()
}

#[test]
fn vectors_directory_is_populated() {
    let vs = load_vectors();
    assert!(
        vs.len() >= 5,
        "expected at least 5 golden vectors, got {} (see tests/wire_compat/README.md)",
        vs.len()
    );
}

#[test]
fn rust_pack_matches_golden() {
    for v in load_vectors() {
        let group_key = B64
            .decode(v.group_key_b64.as_bytes())
            .expect("group_key b64");
        let conv = B64
            .decode(v.conversation_id_b64.as_bytes())
            .expect("conv b64");
        let msg = B64.decode(v.message_id_b64.as_bytes()).expect("msg b64");
        let nonce = B64.decode(v.nonce_b64.as_bytes()).expect("nonce b64");
        let seed = B64.decode(v.signing_seed_b64.as_bytes()).expect("seed b64");
        let expected_sig = B64
            .decode(v.expected_signature_b64.as_bytes())
            .expect("sig b64");

        let out = pack_grp2(Grp2PackInput {
            group_key: &group_key,
            conversation_id: &conv,
            message_id: &msg,
            nonce: &nonce,
            plaintext: v.plaintext_utf8.as_bytes(),
            signing_seed: &seed,
        })
        .unwrap_or_else(|e| panic!("vector {} pack failed: {e}", v.name));

        assert_eq!(
            out.wire_with_prefix, v.expected_wire_with_prefix,
            "vector {} ({}): Rust wire output diverged from golden. \
             If this is intentional, regenerate goldens (see README).",
            v.name, v.description
        );
        assert_eq!(
            out.signature.to_vec(),
            expected_sig,
            "vector {}: Rust signature diverged from golden",
            v.name
        );
    }
}

#[test]
fn rust_unpack_roundtrips_golden() {
    for v in load_vectors() {
        let group_key = B64.decode(v.group_key_b64.as_bytes()).unwrap();
        let conv = B64.decode(v.conversation_id_b64.as_bytes()).unwrap();
        let msg = B64.decode(v.message_id_b64.as_bytes()).unwrap();
        let verify = B64.decode(v.verify_key_b64.as_bytes()).unwrap();

        let pt = unpack_grp2(Grp2UnpackInput {
            wire_with_prefix: &v.expected_wire_with_prefix,
            group_key: &group_key,
            expected_conversation_id: &conv,
            expected_message_id: &msg,
            sender_verify_key: &verify,
        })
        .unwrap_or_else(|e| panic!("vector {} unpack failed: {e}", v.name));
        let pt_str = String::from_utf8(pt).expect("plaintext was not utf-8");
        assert_eq!(
            pt_str, v.plaintext_utf8,
            "vector {}: decrypted plaintext diverged from golden",
            v.name
        );
    }
}
