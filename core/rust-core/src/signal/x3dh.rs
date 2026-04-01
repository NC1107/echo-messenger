//! Extended Triple Diffie-Hellman (X3DH) key agreement.
//!
//! Implements the Signal Protocol X3DH specification for asynchronous
//! session establishment between two parties. The initiator (Alice) can
//! establish a shared secret with the responder (Bob) using Bob's
//! published prekey bundle, without Bob being online.
//!
//! Reference: <https://signal.org/docs/specifications/x3dh/>

use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

use super::keys::{EphemeralKeyPair, IdentityKeyPair, PreKeyBundle};
use crate::error::CoreError;

/// Info string for the X3DH HKDF derivation.
const X3DH_HKDF_INFO: &[u8] = b"EchoSignalX3DH";

/// Result of an X3DH initiation by Alice.
pub struct X3dhInitResult {
    /// 32-byte shared secret derived from X3DH.
    pub shared_secret: [u8; 32],
    /// Alice's ephemeral public key -- sent to Bob in the initial message header.
    pub ephemeral_public: PublicKey,
    /// Alice's identity public key -- sent to Bob so he can compute the same secret.
    pub identity_public: PublicKey,
}

/// Derive a 32-byte key from concatenated DH outputs via HKDF-SHA256.
///
/// Uses a 32-byte zero salt as specified by the Signal protocol.
fn kdf(dh_concat: &[u8]) -> Result<[u8; 32], CoreError> {
    let salt = [0u8; 32];
    let hk = Hkdf::<Sha256>::new(Some(&salt), dh_concat);
    let mut okm = [0u8; 32];
    hk.expand(X3DH_HKDF_INFO, &mut okm)
        .map_err(|e| CoreError::Crypto(format!("X3DH HKDF expand failed: {e}")))?;
    Ok(okm)
}

/// Alice initiates X3DH with Bob's prekey bundle.
///
/// Steps:
/// 1. Verify Bob's signed prekey signature
/// 2. Generate ephemeral key pair
/// 3. Compute 3 or 4 DH operations
/// 4. Derive shared secret via HKDF
pub fn initiate(
    alice_identity: &IdentityKeyPair,
    bob_bundle: &PreKeyBundle,
    bob_verifying_key: &ed25519_dalek::VerifyingKey,
) -> Result<X3dhInitResult, CoreError> {
    // Step 1: Verify the signed prekey signature
    bob_bundle.verify_signature(bob_verifying_key)?;

    // Step 2: Generate ephemeral key pair
    let ephemeral = EphemeralKeyPair::generate();

    // Step 3: Compute DH values
    // DH1 = DH(alice_identity_private, bob_signed_prekey)
    let dh1 = alice_identity
        .private
        .diffie_hellman(&bob_bundle.signed_prekey);
    // DH2 = DH(alice_ephemeral_private, bob_identity_key)
    let dh2 = ephemeral.private.diffie_hellman(&bob_bundle.identity_key);
    // DH3 = DH(alice_ephemeral_private, bob_signed_prekey)
    let dh3 = ephemeral.private.diffie_hellman(&bob_bundle.signed_prekey);

    let mut dh_concat = Vec::with_capacity(32 * 4);
    dh_concat.extend_from_slice(dh1.as_bytes());
    dh_concat.extend_from_slice(dh2.as_bytes());
    dh_concat.extend_from_slice(dh3.as_bytes());

    // DH4 = DH(alice_ephemeral_private, bob_one_time_prekey) [optional]
    if let Some(ref otp) = bob_bundle.one_time_prekey {
        let dh4 = ephemeral.private.diffie_hellman(otp);
        dh_concat.extend_from_slice(dh4.as_bytes());
    }

    // Step 4: Derive shared secret
    let shared_secret = kdf(&dh_concat)?;

    Ok(X3dhInitResult {
        shared_secret,
        ephemeral_public: ephemeral.public,
        identity_public: alice_identity.public,
    })
}

/// Bob responds to Alice's X3DH initiation.
///
/// Bob computes the same DH operations from his perspective using his
/// private keys and Alice's public keys received in the message header.
pub fn respond(
    bob_identity: &IdentityKeyPair,
    bob_signed_prekey_private: &StaticSecret,
    bob_one_time_prekey_private: Option<&StaticSecret>,
    alice_identity_public: &PublicKey,
    alice_ephemeral_public: &PublicKey,
) -> Result<[u8; 32], CoreError> {
    // DH1 = DH(bob_signed_prekey_private, alice_identity_public)
    let dh1 = bob_signed_prekey_private.diffie_hellman(alice_identity_public);
    // DH2 = DH(bob_identity_private, alice_ephemeral_public)
    let dh2 = bob_identity.private.diffie_hellman(alice_ephemeral_public);
    // DH3 = DH(bob_signed_prekey_private, alice_ephemeral_public)
    let dh3 = bob_signed_prekey_private.diffie_hellman(alice_ephemeral_public);

    let mut dh_concat = Vec::with_capacity(32 * 4);
    dh_concat.extend_from_slice(dh1.as_bytes());
    dh_concat.extend_from_slice(dh2.as_bytes());
    dh_concat.extend_from_slice(dh3.as_bytes());

    // DH4 = DH(bob_one_time_prekey_private, alice_ephemeral_public) [optional]
    if let Some(otp_private) = bob_one_time_prekey_private {
        let dh4 = otp_private.diffie_hellman(alice_ephemeral_public);
        dh_concat.extend_from_slice(dh4.as_bytes());
    }

    kdf(&dh_concat)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;

    /// Helper: create Bob's prekey bundle and return all his secrets.
    fn bob_setup() -> (
        IdentityKeyPair,
        StaticSecret,
        PublicKey,
        StaticSecret,
        PublicKey,
        PreKeyBundle,
    ) {
        let bob_identity = IdentityKeyPair::generate();

        let bob_spk_private = StaticSecret::random_from_rng(OsRng);
        let bob_spk_public = PublicKey::from(&bob_spk_private);
        let spk_sig = bob_identity.sign(bob_spk_public.as_bytes());

        let bob_otp_private = StaticSecret::random_from_rng(OsRng);
        let bob_otp_public = PublicKey::from(&bob_otp_private);

        let bundle = PreKeyBundle {
            identity_key: bob_identity.public,
            signed_prekey: bob_spk_public,
            signed_prekey_signature: spk_sig,
            one_time_prekey: Some(bob_otp_public),
        };

        (
            bob_identity,
            bob_spk_private,
            bob_spk_public,
            bob_otp_private,
            bob_otp_public,
            bundle,
        )
    }

    #[test]
    fn test_x3dh_shared_secret_matches_with_otp() {
        let alice = IdentityKeyPair::generate();
        let (bob_identity, bob_spk_priv, _, bob_otp_priv, _, bundle) = bob_setup();

        let bob_verifying = bob_identity.verifying_key();
        let init_result = initiate(&alice, &bundle, &bob_verifying).unwrap();

        let bob_secret = respond(
            &bob_identity,
            &bob_spk_priv,
            Some(&bob_otp_priv),
            &init_result.identity_public,
            &init_result.ephemeral_public,
        )
        .unwrap();

        assert_eq!(init_result.shared_secret, bob_secret);
    }

    #[test]
    fn test_x3dh_shared_secret_matches_without_otp() {
        let alice = IdentityKeyPair::generate();
        let bob_identity = IdentityKeyPair::generate();

        let bob_spk_priv = StaticSecret::random_from_rng(OsRng);
        let bob_spk_pub = PublicKey::from(&bob_spk_priv);
        let spk_sig = bob_identity.sign(bob_spk_pub.as_bytes());

        let bundle = PreKeyBundle {
            identity_key: bob_identity.public,
            signed_prekey: bob_spk_pub,
            signed_prekey_signature: spk_sig,
            one_time_prekey: None,
        };

        let bob_verifying = bob_identity.verifying_key();
        let init_result = initiate(&alice, &bundle, &bob_verifying).unwrap();

        let bob_secret = respond(
            &bob_identity,
            &bob_spk_priv,
            None,
            &init_result.identity_public,
            &init_result.ephemeral_public,
        )
        .unwrap();

        assert_eq!(init_result.shared_secret, bob_secret);
    }

    #[test]
    fn test_x3dh_rejects_bad_signature() {
        let alice = IdentityKeyPair::generate();
        let evil = IdentityKeyPair::generate();
        let bob_identity = IdentityKeyPair::generate();

        let bob_spk_priv = StaticSecret::random_from_rng(OsRng);
        let bob_spk_pub = PublicKey::from(&bob_spk_priv);
        // Sign with evil's key, not Bob's
        let bad_sig = evil.sign(bob_spk_pub.as_bytes());

        let bundle = PreKeyBundle {
            identity_key: bob_identity.public,
            signed_prekey: bob_spk_pub,
            signed_prekey_signature: bad_sig,
            one_time_prekey: None,
        };

        let bob_verifying = bob_identity.verifying_key();
        let result = initiate(&alice, &bundle, &bob_verifying);
        assert!(result.is_err());
    }

    #[test]
    fn test_x3dh_different_initiators_produce_different_secrets() {
        let alice = IdentityKeyPair::generate();
        let eve = IdentityKeyPair::generate();
        let (bob_identity, _, _, _, _, bundle) = bob_setup();

        let bob_verifying = bob_identity.verifying_key();
        let alice_result = initiate(&alice, &bundle, &bob_verifying).unwrap();
        let eve_result = initiate(&eve, &bundle, &bob_verifying).unwrap();

        assert_ne!(alice_result.shared_secret, eve_result.shared_secret);
    }
}
