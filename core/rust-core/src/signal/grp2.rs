//! GRP2 group wire format — reference implementation.
//!
//! See `docs/group-e2e-design/03-recommended-protocol.md` and the Dart
//! production implementation in
//! `apps/client/lib/src/services/group_crypto_service.dart`. This module
//! exists to (a) document the wire format in a typed reference language
//! and (b) back the cross-implementation wire-compat test suite under
//! `tests/wire_compat/`.
//!
//! Wire layout AFTER the textual `GRP2:` prefix and base64 decoding:
//!
//! ```text
//! version_byte(1) || nonce(12) || ciphertext || tag(16) || sig(64)
//! ```
//!
//! `version_byte` is currently `0x01` (the GRP2 revision; the textual
//! prefix never changes).
//!
//! Sender signature is Ed25519 over the payload:
//!
//! ```text
//! version_byte(1) || conv_id(16) || msg_id(16) || nonce(12)
//!                 || ciphertext || tag(16)
//! ```
//!
//! `conv_id` and `msg_id` are bound into the signature so a hostile
//! server cannot rewrite (conv, msg) metadata without invalidating the
//! signature. AES-GCM here carries NO AAD; the auth context lives
//! entirely in the signed payload.

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

use crate::error::CoreError;

/// Textual prefix for a GRP2-format group message. Receivers dispatch on
/// this prefix to route past the legacy GRP1 decryption path.
pub const GRP2_PREFIX: &str = "GRP2:";

/// Current GRP2 revision. Future revisions bump this byte without
/// changing the textual prefix, so receivers can dispatch on the leading
/// version byte after base64 decoding.
pub const GRP2_VERSION: u8 = 0x01;

/// AES-256 group key length.
pub const GROUP_KEY_LEN: usize = 32;
/// AES-GCM nonce length (12 bytes).
pub const NONCE_LEN: usize = 12;
/// AES-GCM authentication tag length (16 bytes).
pub const TAG_LEN: usize = 16;
/// Ed25519 signature length (64 bytes).
pub const SIG_LEN: usize = 64;
/// Raw UUID byte length (16 bytes).
pub const UUID_LEN: usize = 16;

/// Inputs to a GRP2 pack. All byte fields use raw, unencoded bytes.
#[derive(Debug, Clone)]
pub struct Grp2PackInput<'a> {
    /// Raw 32-byte AES-256 group key.
    pub group_key: &'a [u8],
    /// Raw 16-byte conversation UUID (NOT the 36-char string form).
    pub conversation_id: &'a [u8],
    /// Raw 16-byte message UUID. Sender mints this locally.
    pub message_id: &'a [u8],
    /// Raw 12-byte AES-GCM nonce. Caller picks; in production the Dart
    /// sender draws this from the system CSPRNG, but the cross-impl
    /// goldens pin it for determinism.
    pub nonce: &'a [u8],
    /// UTF-8 plaintext bytes.
    pub plaintext: &'a [u8],
    /// 32-byte Ed25519 signing key seed (NOT the expanded 64-byte form).
    pub signing_seed: &'a [u8],
}

/// Output of a successful GRP2 pack.
#[derive(Debug, Clone)]
pub struct Grp2PackOutput {
    /// Full wire frame with the `GRP2:` prefix, base64 of:
    /// `version || nonce || ct || tag || sig`.
    pub wire_with_prefix: String,
    /// Just the inner Ed25519 signature, separately exposed so cross-impl
    /// goldens can assert the signature matches even when the rest of
    /// the wire is empty (zero-byte plaintext edge case).
    pub signature: [u8; SIG_LEN],
    /// Raw ciphertext (without tag), useful for golden inspection.
    pub ciphertext: Vec<u8>,
    /// AES-GCM authentication tag.
    pub tag: [u8; TAG_LEN],
}

/// Build the signature payload bound to a GRP2 message. Lives as a
/// stand-alone helper because both pack and unpack must reproduce it
/// byte-for-byte; any divergence breaks every message.
pub fn signature_payload(
    version: u8,
    conversation_id: &[u8],
    message_id: &[u8],
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
) -> Result<Vec<u8>, CoreError> {
    if conversation_id.len() != UUID_LEN {
        return Err(CoreError::Crypto(format!(
            "conversation_id must be {UUID_LEN} bytes, got {}",
            conversation_id.len()
        )));
    }
    if message_id.len() != UUID_LEN {
        return Err(CoreError::Crypto(format!(
            "message_id must be {UUID_LEN} bytes, got {}",
            message_id.len()
        )));
    }
    if nonce.len() != NONCE_LEN {
        return Err(CoreError::Crypto(format!(
            "nonce must be {NONCE_LEN} bytes, got {}",
            nonce.len()
        )));
    }
    if tag.len() != TAG_LEN {
        return Err(CoreError::Crypto(format!(
            "tag must be {TAG_LEN} bytes, got {}",
            tag.len()
        )));
    }
    let mut out =
        Vec::with_capacity(1 + UUID_LEN + UUID_LEN + NONCE_LEN + ciphertext.len() + TAG_LEN);
    out.push(version);
    out.extend_from_slice(conversation_id);
    out.extend_from_slice(message_id);
    out.extend_from_slice(nonce);
    out.extend_from_slice(ciphertext);
    out.extend_from_slice(tag);
    Ok(out)
}

/// Encrypt + sign a GRP2 message with caller-supplied nonce and signing
/// seed. This is the reference packer; production senders use a random
/// nonce, but for goldens the caller pins it.
pub fn pack_grp2(input: Grp2PackInput<'_>) -> Result<Grp2PackOutput, CoreError> {
    if input.group_key.len() != GROUP_KEY_LEN {
        return Err(CoreError::Crypto(format!(
            "group_key must be {GROUP_KEY_LEN} bytes, got {}",
            input.group_key.len()
        )));
    }
    if input.nonce.len() != NONCE_LEN {
        return Err(CoreError::Crypto(format!(
            "nonce must be {NONCE_LEN} bytes, got {}",
            input.nonce.len()
        )));
    }
    if input.conversation_id.len() != UUID_LEN {
        return Err(CoreError::Crypto(format!(
            "conversation_id must be {UUID_LEN} bytes"
        )));
    }
    if input.message_id.len() != UUID_LEN {
        return Err(CoreError::Crypto(format!(
            "message_id must be {UUID_LEN} bytes"
        )));
    }
    if input.signing_seed.len() != 32 {
        return Err(CoreError::Crypto(format!(
            "signing_seed must be 32 bytes (Ed25519 seed), got {}",
            input.signing_seed.len()
        )));
    }

    // AES-256-GCM, no AAD (auth context lives in the signed payload).
    let cipher = Aes256Gcm::new_from_slice(input.group_key)
        .map_err(|e| CoreError::Crypto(format!("AES key init: {e}")))?;
    let nonce_arr = Nonce::from_slice(input.nonce);
    let ct_with_tag = cipher
        .encrypt(nonce_arr, input.plaintext)
        .map_err(|e| CoreError::Crypto(format!("AES-GCM encrypt: {e}")))?;
    // aes-gcm returns ciphertext || tag concatenated.
    if ct_with_tag.len() < TAG_LEN {
        return Err(CoreError::Crypto(
            "AES-GCM output shorter than tag length (impossible)".into(),
        ));
    }
    let ct_len = ct_with_tag.len() - TAG_LEN;
    let ciphertext = ct_with_tag[..ct_len].to_vec();
    let mut tag = [0u8; TAG_LEN];
    tag.copy_from_slice(&ct_with_tag[ct_len..]);

    // Sign payload.
    let payload = signature_payload(
        GRP2_VERSION,
        input.conversation_id,
        input.message_id,
        input.nonce,
        &ciphertext,
        &tag,
    )?;
    let seed_arr: [u8; 32] = input
        .signing_seed
        .try_into()
        .map_err(|_| CoreError::Crypto("signing_seed not 32 bytes".into()))?;
    let signing_key = SigningKey::from_bytes(&seed_arr);
    let signature: Signature = signing_key.sign(&payload);
    let sig_bytes = signature.to_bytes();

    // Assemble wire: version(1) || nonce(12) || ct || tag(16) || sig(64).
    let mut wire = Vec::with_capacity(1 + NONCE_LEN + ciphertext.len() + TAG_LEN + SIG_LEN);
    wire.push(GRP2_VERSION);
    wire.extend_from_slice(input.nonce);
    wire.extend_from_slice(&ciphertext);
    wire.extend_from_slice(&tag);
    wire.extend_from_slice(&sig_bytes);

    let mut wire_with_prefix = String::from(GRP2_PREFIX);
    wire_with_prefix.push_str(&B64.encode(&wire));

    Ok(Grp2PackOutput {
        wire_with_prefix,
        signature: sig_bytes,
        ciphertext,
        tag,
    })
}

/// Inputs to a GRP2 unpack.
#[derive(Debug, Clone)]
pub struct Grp2UnpackInput<'a> {
    pub wire_with_prefix: &'a str,
    pub group_key: &'a [u8],
    pub expected_conversation_id: &'a [u8],
    pub expected_message_id: &'a [u8],
    /// 32-byte Ed25519 public verifying key.
    pub sender_verify_key: &'a [u8],
}

/// Verify signature then decrypt. Mirrors the Dart
/// `verifyAndDecryptGroupMessageV2` shape: signature failures are a
/// hard error distinct from AEAD failures.
pub fn unpack_grp2(input: Grp2UnpackInput<'_>) -> Result<Vec<u8>, CoreError> {
    if !input.wire_with_prefix.starts_with(GRP2_PREFIX) {
        return Err(CoreError::Crypto("missing GRP2: prefix".into()));
    }
    let b64 = &input.wire_with_prefix[GRP2_PREFIX.len()..];
    let wire = B64
        .decode(b64.as_bytes())
        .map_err(|e| CoreError::Crypto(format!("base64 decode: {e}")))?;

    let min_len = 1 + NONCE_LEN + TAG_LEN + SIG_LEN;
    if wire.len() < min_len {
        return Err(CoreError::Crypto(format!(
            "GRP2 wire too short: {} bytes (min {min_len})",
            wire.len()
        )));
    }

    let version = wire[0];
    if version != GRP2_VERSION {
        return Err(CoreError::Crypto(format!(
            "unsupported GRP2 revision: 0x{version:02x}"
        )));
    }

    let nonce = &wire[1..1 + NONCE_LEN];
    let sig_start = wire.len() - SIG_LEN;
    let tag_start = sig_start - TAG_LEN;
    let ciphertext = &wire[1 + NONCE_LEN..tag_start];
    let tag = &wire[tag_start..sig_start];
    let signature_bytes = &wire[sig_start..];

    let payload = signature_payload(
        version,
        input.expected_conversation_id,
        input.expected_message_id,
        nonce,
        ciphertext,
        tag,
    )?;
    let vk_arr: [u8; 32] = input
        .sender_verify_key
        .try_into()
        .map_err(|_| CoreError::Crypto("sender_verify_key must be 32 bytes".into()))?;
    let verify_key = VerifyingKey::from_bytes(&vk_arr)
        .map_err(|e| CoreError::Crypto(format!("verify key parse: {e}")))?;
    let sig_arr: [u8; SIG_LEN] = signature_bytes
        .try_into()
        .map_err(|_| CoreError::Crypto("signature not 64 bytes".into()))?;
    let signature = Signature::from_bytes(&sig_arr);
    verify_key
        .verify(&payload, &signature)
        .map_err(|_| CoreError::Crypto("Ed25519 sender signature did not verify".into()))?;

    if input.group_key.len() != GROUP_KEY_LEN {
        return Err(CoreError::Crypto(format!(
            "group_key must be {GROUP_KEY_LEN} bytes"
        )));
    }
    let cipher = Aes256Gcm::new_from_slice(input.group_key)
        .map_err(|e| CoreError::Crypto(format!("AES key init: {e}")))?;
    let nonce_arr = Nonce::from_slice(nonce);
    // aes-gcm expects ct || tag concatenated for decrypt.
    let mut ct_with_tag = Vec::with_capacity(ciphertext.len() + TAG_LEN);
    ct_with_tag.extend_from_slice(ciphertext);
    ct_with_tag.extend_from_slice(tag);
    let plaintext = cipher
        .decrypt(nonce_arr, ct_with_tag.as_ref())
        .map_err(|e| CoreError::Crypto(format!("AES-GCM decrypt: {e}")))?;
    Ok(plaintext)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FixedInputs {
        group_key: Vec<u8>,
        conv_id: Vec<u8>,
        msg_id: Vec<u8>,
        nonce: Vec<u8>,
        signing_seed: Vec<u8>,
    }

    fn fixed_inputs() -> FixedInputs {
        FixedInputs {
            group_key: vec![0x42u8; 32],
            conv_id: (1u8..=16).collect(),
            msg_id: (100u8..=115).collect(),
            nonce: (0u8..12).collect(),
            signing_seed: vec![0x7Au8; 32],
        }
    }

    #[test]
    fn pack_unpack_roundtrip() {
        let f = fixed_inputs();
        let seed_arr: [u8; 32] = f.signing_seed.as_slice().try_into().unwrap();
        let signing_key = SigningKey::from_bytes(&seed_arr);
        let verify = signing_key.verifying_key().to_bytes();

        let out = pack_grp2(Grp2PackInput {
            group_key: &f.group_key,
            conversation_id: &f.conv_id,
            message_id: &f.msg_id,
            nonce: &f.nonce,
            plaintext: b"hello reference",
            signing_seed: &f.signing_seed,
        })
        .unwrap();
        assert!(out.wire_with_prefix.starts_with(GRP2_PREFIX));

        let pt = unpack_grp2(Grp2UnpackInput {
            wire_with_prefix: &out.wire_with_prefix,
            group_key: &f.group_key,
            expected_conversation_id: &f.conv_id,
            expected_message_id: &f.msg_id,
            sender_verify_key: &verify,
        })
        .unwrap();
        assert_eq!(pt, b"hello reference");
    }

    #[test]
    fn forged_signature_rejected() {
        let f = fixed_inputs();
        let out = pack_grp2(Grp2PackInput {
            group_key: &f.group_key,
            conversation_id: &f.conv_id,
            message_id: &f.msg_id,
            nonce: &f.nonce,
            plaintext: b"x",
            signing_seed: &f.signing_seed,
        })
        .unwrap();
        let bad_verify = [0u8; 32];
        let err = unpack_grp2(Grp2UnpackInput {
            wire_with_prefix: &out.wire_with_prefix,
            group_key: &f.group_key,
            expected_conversation_id: &f.conv_id,
            expected_message_id: &f.msg_id,
            sender_verify_key: &bad_verify,
        });
        assert!(err.is_err());
    }
}
