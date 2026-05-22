//! One-shot generator for GRP2 wire-compat golden vectors.
//!
//! Usage:
//!     cargo run -p echo-core --example gen_grp2_vectors -- <out_dir>
//!
//! Writes one JSON file per vector to `<out_dir>`. Run this only when the
//! wire format intentionally changes (and bump the GRP2 version byte in
//! lockstep). The cross-impl tests in `core/rust-core/tests/wire_compat.rs`
//! and `apps/client/test/services/group_crypto_wire_compat_test.dart`
//! consume the resulting JSON.

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use echo_core::signal::grp2::{Grp2PackInput, pack_grp2};
use ed25519_dalek::SigningKey;
use serde::Serialize;
use std::path::PathBuf;

#[derive(Serialize)]
struct Vector {
    name: String,
    description: String,
    group_key_b64: String,
    conversation_id_b64: String,
    message_id_b64: String,
    nonce_b64: String,
    signing_seed_b64: String,
    verify_key_b64: String,
    plaintext_utf8: String,
    expected_wire_with_prefix: String,
    expected_signature_b64: String,
}

struct Spec {
    name: &'static str,
    description: &'static str,
    group_key: [u8; 32],
    conversation_id: [u8; 16],
    message_id: [u8; 16],
    nonce: [u8; 12],
    signing_seed: [u8; 32],
    plaintext: String,
}

fn fill_pattern(byte: u8, len: usize) -> Vec<u8> {
    vec![byte; len]
}

fn arr32(b: u8) -> [u8; 32] {
    [b; 32]
}
fn arr16(b: u8) -> [u8; 16] {
    [b; 16]
}
fn arr12(b: u8) -> [u8; 12] {
    [b; 12]
}

fn build_specs() -> Vec<Spec> {
    vec![
        Spec {
            name: "01-empty-plaintext",
            description: "zero-byte plaintext exercises the minimum wire length \
                          (version+nonce+tag+sig with no ciphertext).",
            group_key: arr32(0x11),
            conversation_id: arr16(0xA1),
            message_id: arr16(0xB1),
            nonce: arr12(0x01),
            signing_seed: arr32(0x21),
            plaintext: String::new(),
        },
        Spec {
            name: "02-single-byte",
            description: "single-byte plaintext (smallest non-empty payload).",
            group_key: arr32(0x22),
            conversation_id: arr16(0xA2),
            message_id: arr16(0xB2),
            nonce: arr12(0x02),
            signing_seed: arr32(0x32),
            plaintext: "x".to_string(),
        },
        Spec {
            name: "03-short-ascii",
            description: "short ASCII plaintext, the common chat case.",
            group_key: arr32(0x33),
            conversation_id: arr16(0xA3),
            message_id: arr16(0xB3),
            nonce: arr12(0x03),
            signing_seed: arr32(0x43),
            plaintext: "hello signed group".to_string(),
        },
        Spec {
            name: "04-utf8-emoji",
            description: "multi-byte UTF-8 (emoji + non-ASCII) exercises that the \
                          Dart utf8.encode path matches Rust's str::as_bytes.",
            group_key: arr32(0x44),
            conversation_id: arr16(0xA4),
            message_id: arr16(0xB4),
            nonce: arr12(0x04),
            signing_seed: arr32(0x54),
            plaintext: "héllo 🙂 群组 GRP2".to_string(),
        },
        Spec {
            name: "05-aes-block-boundary",
            description: "plaintext exactly 16 bytes — the AES-128 block size. \
                          Catches off-by-one bugs in either impl's CTR-mode \
                          padding boundary handling.",
            group_key: arr32(0x55),
            conversation_id: arr16(0xA5),
            message_id: arr16(0xB5),
            nonce: arr12(0x05),
            signing_seed: arr32(0x65),
            plaintext: "0123456789ABCDEF".to_string(),
        },
        Spec {
            name: "06-multi-block",
            description: "multi-block plaintext (~5 AES blocks) catches CTR mode \
                          bugs that only fire after the first counter increment.",
            group_key: arr32(0x66),
            conversation_id: arr16(0xA6),
            message_id: arr16(0xB6),
            nonce: arr12(0x06),
            signing_seed: arr32(0x76),
            plaintext: "0123456789ABCDEF".repeat(5),
        },
        Spec {
            name: "07-distinct-keys-ids",
            description: "every input byte distinct from every other — guards \
                          against accidental swap bugs between key/conv/msg/nonce \
                          fields (e.g. signing the wrong UUID).",
            group_key: {
                let mut k = [0u8; 32];
                for (i, b) in k.iter_mut().enumerate() {
                    *b = i as u8;
                }
                k
            },
            conversation_id: {
                let mut c = [0u8; 16];
                for (i, b) in c.iter_mut().enumerate() {
                    *b = 0x80 | (i as u8);
                }
                c
            },
            message_id: {
                let mut m = [0u8; 16];
                for (i, b) in m.iter_mut().enumerate() {
                    *b = 0x40 | (i as u8);
                }
                m
            },
            nonce: {
                let mut n = [0u8; 12];
                for (i, b) in n.iter_mut().enumerate() {
                    *b = 0xC0 | (i as u8);
                }
                n
            },
            signing_seed: {
                let mut s = [0u8; 32];
                for (i, b) in s.iter_mut().enumerate() {
                    *b = 0xFF - (i as u8);
                }
                s
            },
            plaintext: "swap-detector".to_string(),
        },
        Spec {
            name: "08-newline-and-null",
            description: "plaintext with embedded NUL and newline bytes — guards \
                          against any impl accidentally treating plaintext as a \
                          C string.",
            group_key: arr32(0x88),
            conversation_id: arr16(0xA8),
            message_id: arr16(0xB8),
            nonce: arr12(0x08),
            signing_seed: arr32(0x98),
            plaintext: "line1\nline2\x00trailing".to_string(),
        },
        Spec {
            name: "09-largish",
            description: "~1 KiB plaintext, exercises that neither impl has a \
                          short-buffer assumption baked in.",
            group_key: arr32(0x99),
            conversation_id: arr16(0xA9),
            message_id: arr16(0xB9),
            nonce: arr12(0x09),
            signing_seed: arr32(0xA9),
            plaintext: String::from_utf8(fill_pattern(b'L', 1024)).unwrap(),
        },
    ]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out_dir = if args.len() >= 2 {
        PathBuf::from(&args[1])
    } else {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("tests")
            .join("wire_compat")
            .join("vectors")
    };
    std::fs::create_dir_all(&out_dir).expect("create out dir");

    for spec in build_specs() {
        let sk = SigningKey::from_bytes(&spec.signing_seed);
        let verify = sk.verifying_key().to_bytes();
        let out = pack_grp2(Grp2PackInput {
            group_key: &spec.group_key,
            conversation_id: &spec.conversation_id,
            message_id: &spec.message_id,
            nonce: &spec.nonce,
            plaintext: spec.plaintext.as_bytes(),
            signing_seed: &spec.signing_seed,
        })
        .expect("pack_grp2");

        let v = Vector {
            name: spec.name.to_string(),
            description: spec.description.to_string(),
            group_key_b64: B64.encode(spec.group_key),
            conversation_id_b64: B64.encode(spec.conversation_id),
            message_id_b64: B64.encode(spec.message_id),
            nonce_b64: B64.encode(spec.nonce),
            signing_seed_b64: B64.encode(spec.signing_seed),
            verify_key_b64: B64.encode(verify),
            plaintext_utf8: spec.plaintext.clone(),
            expected_wire_with_prefix: out.wire_with_prefix,
            expected_signature_b64: B64.encode(out.signature),
        };
        let path = out_dir.join(format!("{}.json", spec.name));
        let json = serde_json::to_string_pretty(&v).expect("serialize vector");
        std::fs::write(&path, json + "\n").expect("write vector");
        println!("wrote {}", path.display());
    }
}
