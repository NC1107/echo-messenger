//! Simplified X3DH key agreement for session establishment.
//!
//! # Deprecation notice
//!
//! [`x3dh_initiate`] and [`x3dh_respond`] are **deprecated** because they
//! accept raw public keys without verifying the recipient's signed-prekey
//! Ed25519 signature, leaving callers open to MITM attacks. Use the
//! [`crate::signal::x3dh`] module instead, which enforces signature
//! verification as part of the initiation handshake.

use hkdf::Hkdf;
use rand_core::OsRng;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::error::CoreError;

/// Result of an X3DH initiation by the sender.
pub struct X3dhResult {
    /// The 32-byte shared secret derived from the key agreement.
    pub shared_secret: [u8; 32],
    /// The ephemeral public key to send to the responder.
    pub ephemeral_public: Vec<u8>,
}

/// Application-specific info string for HKDF.
///
/// MUST match `X3DH_HKDF_INFO` in `signal::x3dh` and the Dart client's
/// `SignalX3DH._hkdfInfo` so that initiator and responder derive identical
/// shared secrets regardless of which implementation is used.
const HKDF_INFO: &[u8] = b"EchoSignalX3DH";

/// Derive a 32-byte key from concatenated DH outputs using HKDF-SHA256.
fn kdf(dh_outputs: &[u8]) -> Result<[u8; 32], CoreError> {
    // Use a fixed salt of 32 zero bytes (as per Signal spec).
    let salt = [0u8; 32];
    let hk = Hkdf::<Sha256>::new(Some(&salt), dh_outputs);
    let mut okm = [0u8; 32];
    hk.expand(HKDF_INFO, &mut okm)
        .map_err(|e| CoreError::Crypto(format!("HKDF expand failed: {e}")))?;
    Ok(okm)
}

/// Initiator performs X3DH with recipient's PreKey bundle.
///
/// Performs up to 4 DH operations:
/// 1. DH(our_identity, their_signed_prekey)
/// 2. DH(ephemeral, their_identity)
/// 3. DH(ephemeral, their_signed_prekey)
/// 4. DH(ephemeral, their_one_time_prekey) -- optional
///
/// # Security
///
/// This helper accepts raw public keys and **does not verify** the recipient's
/// signed-prekey signature. An attacker who can substitute `their_signed_prekey`
/// can perform a man-in-the-middle attack without detection. Use
/// [`crate::signal::x3dh::initiate`] instead, which verifies the Ed25519
/// signature on the signed prekey before performing any DH operations.
#[deprecated(
    since = "0.4.0",
    note = "does not verify the SignedPreKey signature — use `signal::x3dh::initiate` which \
            enforces signature verification and prevents MITM attacks"
)]
pub fn x3dh_initiate(
    our_identity: &StaticSecret,
    their_identity: &PublicKey,
    their_signed_prekey: &PublicKey,
    their_one_time_prekey: Option<&PublicKey>,
) -> Result<X3dhResult, CoreError> {
    // Use StaticSecret for the ephemeral key because EphemeralSecret
    // consumes self on diffie_hellman, but X3DH needs multiple DH ops.
    let ephemeral_secret = StaticSecret::random_from_rng(OsRng);
    let ephemeral_public = PublicKey::from(&ephemeral_secret);

    let dh1 = our_identity.diffie_hellman(their_signed_prekey);
    let dh2 = ephemeral_secret.diffie_hellman(their_identity);
    let dh3 = ephemeral_secret.diffie_hellman(their_signed_prekey);

    let mut dh_concat = Vec::with_capacity(32 * 4);
    dh_concat.extend_from_slice(dh1.as_bytes());
    dh_concat.extend_from_slice(dh2.as_bytes());
    dh_concat.extend_from_slice(dh3.as_bytes());

    if let Some(otk) = their_one_time_prekey {
        let dh4 = ephemeral_secret.diffie_hellman(otk);
        dh_concat.extend_from_slice(dh4.as_bytes());
    }

    let shared_secret = kdf(&dh_concat)?;

    Ok(X3dhResult {
        shared_secret,
        ephemeral_public: ephemeral_public.as_bytes().to_vec(),
    })
}

/// Responder completes X3DH key agreement.
///
/// Mirrors the initiator's DH operations from the responder's perspective.
///
/// # Security
///
/// Signature verification is the initiator's responsibility (see
/// [`x3dh_initiate`]). Because the initiator side of this pair does not verify
/// the SignedPreKey signature, this responder function is also deprecated. Use
/// [`crate::signal::x3dh::respond`] together with
/// [`crate::signal::x3dh::initiate`] for a fully verified session.
#[deprecated(
    since = "0.4.0",
    note = "pair of the unverified `x3dh_initiate` — use `signal::x3dh::respond` instead"
)]
pub fn x3dh_respond(
    our_identity: &StaticSecret,
    our_signed_prekey: &StaticSecret,
    our_one_time_prekey: Option<&StaticSecret>,
    their_identity: &PublicKey,
    their_ephemeral: &PublicKey,
) -> Result<[u8; 32], CoreError> {
    let dh1 = our_signed_prekey.diffie_hellman(their_identity);
    let dh2 = our_identity.diffie_hellman(their_ephemeral);
    let dh3 = our_signed_prekey.diffie_hellman(their_ephemeral);

    let mut dh_concat = Vec::with_capacity(32 * 4);
    dh_concat.extend_from_slice(dh1.as_bytes());
    dh_concat.extend_from_slice(dh2.as_bytes());
    dh_concat.extend_from_slice(dh3.as_bytes());

    if let Some(otk) = our_one_time_prekey {
        let dh4 = otk.diffie_hellman(their_ephemeral);
        dh_concat.extend_from_slice(dh4.as_bytes());
    }

    kdf(&dh_concat)
}

#[cfg(test)]
#[allow(deprecated)] // intentionally exercising the deprecated helpers
mod tests {
    use super::*;

    #[test]
    fn test_x3dh_key_agreement_with_otp() {
        // Simulate Alice (initiator) and Bob (responder).
        let alice_identity = StaticSecret::random_from_rng(OsRng);
        let alice_identity_pub = PublicKey::from(&alice_identity);

        let bob_identity = StaticSecret::random_from_rng(OsRng);
        let bob_identity_pub = PublicKey::from(&bob_identity);

        let bob_signed_prekey = StaticSecret::random_from_rng(OsRng);
        let bob_signed_prekey_pub = PublicKey::from(&bob_signed_prekey);

        let bob_otp = StaticSecret::random_from_rng(OsRng);
        let bob_otp_pub = PublicKey::from(&bob_otp);

        // Alice initiates
        let result = x3dh_initiate(
            &alice_identity,
            &bob_identity_pub,
            &bob_signed_prekey_pub,
            Some(&bob_otp_pub),
        )
        .unwrap();

        let their_ephemeral =
            PublicKey::from(<[u8; 32]>::try_from(result.ephemeral_public.as_slice()).unwrap());

        // Bob responds
        let bob_secret = x3dh_respond(
            &bob_identity,
            &bob_signed_prekey,
            Some(&bob_otp),
            &alice_identity_pub,
            &their_ephemeral,
        )
        .unwrap();

        assert_eq!(result.shared_secret, bob_secret);
    }

    #[test]
    fn test_x3dh_key_agreement_without_otp() {
        let alice_identity = StaticSecret::random_from_rng(OsRng);
        let alice_identity_pub = PublicKey::from(&alice_identity);

        let bob_identity = StaticSecret::random_from_rng(OsRng);
        let bob_identity_pub = PublicKey::from(&bob_identity);

        let bob_signed_prekey = StaticSecret::random_from_rng(OsRng);
        let bob_signed_prekey_pub = PublicKey::from(&bob_signed_prekey);

        // Alice initiates without OTP
        let result = x3dh_initiate(
            &alice_identity,
            &bob_identity_pub,
            &bob_signed_prekey_pub,
            None,
        )
        .unwrap();

        let their_ephemeral =
            PublicKey::from(<[u8; 32]>::try_from(result.ephemeral_public.as_slice()).unwrap());

        // Bob responds without OTP
        let bob_secret = x3dh_respond(
            &bob_identity,
            &bob_signed_prekey,
            None,
            &alice_identity_pub,
            &their_ephemeral,
        )
        .unwrap();

        assert_eq!(result.shared_secret, bob_secret);
    }

    #[test]
    fn test_x3dh_different_identities_produce_different_secrets() {
        let alice_identity = StaticSecret::random_from_rng(OsRng);

        let bob_identity = StaticSecret::random_from_rng(OsRng);
        let bob_identity_pub = PublicKey::from(&bob_identity);

        let bob_signed_prekey = StaticSecret::random_from_rng(OsRng);
        let bob_signed_prekey_pub = PublicKey::from(&bob_signed_prekey);

        let eve_identity = StaticSecret::random_from_rng(OsRng);

        let result_alice = x3dh_initiate(
            &alice_identity,
            &bob_identity_pub,
            &bob_signed_prekey_pub,
            None,
        )
        .unwrap();

        let result_eve = x3dh_initiate(
            &eve_identity,
            &bob_identity_pub,
            &bob_signed_prekey_pub,
            None,
        )
        .unwrap();

        assert_ne!(result_alice.shared_secret, result_eve.shared_secret);
    }

    /// Regression guard: the deprecated helpers must still produce matching
    /// shared secrets so that any in-flight sessions created before the
    /// migration are not silently broken. The migration path is to switch
    /// callers to `signal::x3dh::initiate` / `signal::x3dh::respond`.
    #[test]
    fn test_deprecated_helpers_still_agree() {
        let alice_id = StaticSecret::random_from_rng(OsRng);
        let alice_id_pub = PublicKey::from(&alice_id);

        let bob_id = StaticSecret::random_from_rng(OsRng);
        let bob_id_pub = PublicKey::from(&bob_id);

        let bob_spk = StaticSecret::random_from_rng(OsRng);
        let bob_spk_pub = PublicKey::from(&bob_spk);

        let init = x3dh_initiate(&alice_id, &bob_id_pub, &bob_spk_pub, None).unwrap();
        let their_eph =
            PublicKey::from(<[u8; 32]>::try_from(init.ephemeral_public.as_slice()).unwrap());
        let resp = x3dh_respond(&bob_id, &bob_spk, None, &alice_id_pub, &their_eph).unwrap();

        assert_eq!(
            init.shared_secret, resp,
            "deprecated helpers must still derive matching secrets"
        );
    }
}
