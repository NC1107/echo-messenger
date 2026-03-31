//! Key generation and PreKey bundle management.

use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use rand::rngs::OsRng;
use x25519_dalek::{PublicKey, StaticSecret};

/// Long-term Ed25519 identity key pair used for signing.
pub struct IdentityKeyPair {
    pub signing_key: SigningKey,
    pub verifying_key: VerifyingKey,
}

/// A PreKey bundle to upload to the server for X3DH key agreement.
pub struct PreKeyBundle {
    /// Ed25519 public key (identity key).
    pub identity_key: Vec<u8>,
    /// X25519 signed prekey (public).
    pub signed_prekey: Vec<u8>,
    /// Ed25519 signature over the signed prekey bytes.
    pub signed_prekey_signature: Vec<u8>,
    /// Numeric identifier for the signed prekey.
    pub signed_prekey_id: u32,
    /// One-time prekeys: (id, X25519 public key bytes).
    pub one_time_prekeys: Vec<(u32, Vec<u8>)>,
}

impl IdentityKeyPair {
    /// Generate a new random Ed25519 identity key pair.
    pub fn generate() -> Self {
        let mut secret_bytes = [0u8; 32];
        rand::RngCore::fill_bytes(&mut OsRng, &mut secret_bytes);
        let signing_key = SigningKey::from_bytes(&secret_bytes);
        let verifying_key = signing_key.verifying_key();
        Self {
            signing_key,
            verifying_key,
        }
    }

    /// Return the public identity key bytes (32 bytes).
    pub fn public_key_bytes(&self) -> Vec<u8> {
        self.verifying_key.to_bytes().to_vec()
    }
}

/// Generate a signed prekey: an X25519 key pair signed by the identity key.
///
/// Returns (secret, public_key_bytes, signature_bytes, key_id).
pub fn generate_signed_prekey(
    identity: &IdentityKeyPair,
    key_id: u32,
) -> (StaticSecret, Vec<u8>, Vec<u8>, u32) {
    let secret = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&secret);
    let public_bytes = public.as_bytes().to_vec();

    let signature = identity.signing_key.sign(&public_bytes);
    let sig_bytes = signature.to_bytes().to_vec();

    (secret, public_bytes, sig_bytes, key_id)
}

/// Generate a batch of one-time prekeys.
///
/// Returns a vec of (key_id, secret, public_key_bytes).
pub fn generate_one_time_prekeys(start_id: u32, count: u32) -> Vec<(u32, StaticSecret, Vec<u8>)> {
    (0..count)
        .map(|i| {
            let id = start_id + i;
            let secret = StaticSecret::random_from_rng(OsRng);
            let public = PublicKey::from(&secret);
            (id, secret, public.as_bytes().to_vec())
        })
        .collect()
}

/// Build a complete PreKey bundle ready for upload.
pub fn build_prekey_bundle(
    identity: &IdentityKeyPair,
    signed_prekey_id: u32,
    one_time_prekey_start_id: u32,
    one_time_prekey_count: u32,
) -> (PreKeyBundle, StaticSecret, Vec<(u32, StaticSecret)>) {
    let (spk_secret, spk_public, spk_sig, spk_id) =
        generate_signed_prekey(identity, signed_prekey_id);

    let otps = generate_one_time_prekeys(one_time_prekey_start_id, one_time_prekey_count);
    let otp_publics: Vec<(u32, Vec<u8>)> =
        otps.iter().map(|(id, _, pk)| (*id, pk.clone())).collect();
    let otp_secrets: Vec<(u32, StaticSecret)> = otps
        .into_iter()
        .map(|(id, secret, _)| (id, secret))
        .collect();

    let bundle = PreKeyBundle {
        identity_key: identity.public_key_bytes(),
        signed_prekey: spk_public,
        signed_prekey_signature: spk_sig,
        signed_prekey_id: spk_id,
        one_time_prekeys: otp_publics,
    };

    (bundle, spk_secret, otp_secrets)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::Verifier;

    #[test]
    fn test_identity_key_generation() {
        let identity = IdentityKeyPair::generate();
        let pk_bytes = identity.public_key_bytes();
        assert_eq!(pk_bytes.len(), 32);
    }

    #[test]
    fn test_signed_prekey_generation_and_verification() {
        let identity = IdentityKeyPair::generate();
        let (_secret, public_bytes, sig_bytes, key_id) = generate_signed_prekey(&identity, 1);

        assert_eq!(key_id, 1);
        assert_eq!(public_bytes.len(), 32);
        assert_eq!(sig_bytes.len(), 64);

        // Verify the signature
        let sig = ed25519_dalek::Signature::from_bytes(sig_bytes.as_slice().try_into().unwrap());
        assert!(identity.verifying_key.verify(&public_bytes, &sig).is_ok());
    }

    #[test]
    fn test_one_time_prekey_generation() {
        let otps = generate_one_time_prekeys(0, 10);
        assert_eq!(otps.len(), 10);
        for (i, (id, _secret, pk)) in otps.iter().enumerate() {
            assert_eq!(*id, i as u32);
            assert_eq!(pk.len(), 32);
        }
        // Verify all public keys are unique
        let mut seen = std::collections::HashSet::new();
        for (_, _, pk) in &otps {
            assert!(seen.insert(pk.clone()), "Duplicate one-time prekey found");
        }
    }

    #[test]
    fn test_build_prekey_bundle() {
        let identity = IdentityKeyPair::generate();
        let (bundle, _spk_secret, otp_secrets) = build_prekey_bundle(&identity, 1, 0, 10);

        assert_eq!(bundle.identity_key.len(), 32);
        assert_eq!(bundle.signed_prekey.len(), 32);
        assert_eq!(bundle.signed_prekey_signature.len(), 64);
        assert_eq!(bundle.signed_prekey_id, 1);
        assert_eq!(bundle.one_time_prekeys.len(), 10);
        assert_eq!(otp_secrets.len(), 10);
    }
}
