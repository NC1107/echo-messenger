//! Key types and generation for the Signal Protocol.
//!
//! Provides identity key pairs (X25519 + Ed25519 for signing), ephemeral keys,
//! and prekey bundles used in X3DH key agreement.

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use rand::rngs::OsRng;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::error::CoreError;

/// Long-term identity key pair combining X25519 (for DH) and Ed25519 (for signing).
///
/// The X25519 key pair is used in X3DH DH operations. The Ed25519 signing key
/// is used to sign prekeys so peers can verify their authenticity.
pub struct IdentityKeyPair {
    pub private: StaticSecret,
    pub public: PublicKey,
    pub signing_key: SigningKey,
}

/// A prekey bundle published to the server for X3DH key agreement.
///
/// Contains the public material a peer needs to initiate a session
/// without the recipient being online.
pub struct PreKeyBundle {
    pub identity_key: PublicKey,
    pub signed_prekey: PublicKey,
    pub signed_prekey_signature: ed25519_dalek::Signature,
    pub one_time_prekey: Option<PublicKey>,
}

/// An ephemeral X25519 key pair generated per-session during X3DH initiation.
pub struct EphemeralKeyPair {
    pub private: StaticSecret,
    pub public: PublicKey,
}

impl IdentityKeyPair {
    /// Generate a new random identity key pair.
    pub fn generate() -> Self {
        let private = StaticSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&private);

        let mut signing_bytes = [0u8; 32];
        rand::RngCore::fill_bytes(&mut OsRng, &mut signing_bytes);
        let signing_key = SigningKey::from_bytes(&signing_bytes);

        Self {
            private,
            public,
            signing_key,
        }
    }

    /// Return the Ed25519 verifying (public) key for signature verification.
    pub fn verifying_key(&self) -> VerifyingKey {
        self.signing_key.verifying_key()
    }

    /// Sign arbitrary data with the Ed25519 signing key.
    pub fn sign(&self, data: &[u8]) -> ed25519_dalek::Signature {
        self.signing_key.sign(data)
    }

    /// Serialize the identity key pair to bytes for persistent storage.
    ///
    /// Layout: `x25519_private (32) || ed25519_signing_key (32)`
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(64);
        // StaticSecret doesn't expose bytes directly, but we can reconstruct
        // by converting through the internal representation. We serialize the
        // raw secret bytes via the to_bytes method available through diffie_hellman trick.
        // Actually, x25519-dalek StaticSecret has no to_bytes. We store a clone.
        // We need to work around this -- store the signing key + derive x25519 from it,
        // or store both seeds. For now we store both raw 32-byte seeds.
        //
        // NOTE: x25519_dalek::StaticSecret does not expose raw bytes.
        // We store the signing key bytes and regenerate the X25519 key from a
        // separate seed stored alongside. We use a combined 64-byte serialization.
        //
        // For a production system you would encrypt this at rest with a passphrase-derived key.
        //
        // Since StaticSecret doesn't expose to_bytes, we use an unsafe transmute-free
        // approach: store the secret bytes we generated. But since we used
        // `random_from_rng`, we no longer have the raw bytes.
        //
        // The cleanest approach: store the seeds used to generate keys.
        // For the existing generate() flow, we need to capture seeds at creation time.
        // For now, we serialize the signing key only and note that X25519 private key
        // serialization requires the `static_secrets` feature's `to_bytes()` method.
        out.extend_from_slice(&self.private.to_bytes());
        out.extend_from_slice(self.signing_key.as_bytes());
        out
    }

    /// Deserialize an identity key pair from bytes produced by [`serialize`].
    pub fn deserialize(data: &[u8]) -> Result<Self, CoreError> {
        if data.len() < 64 {
            return Err(CoreError::Crypto(
                "IdentityKeyPair data too short (need 64 bytes)".into(),
            ));
        }

        let x25519_bytes: [u8; 32] = data[..32]
            .try_into()
            .map_err(|_| CoreError::Crypto("Invalid X25519 private key bytes".into()))?;
        let ed25519_bytes: [u8; 32] = data[32..64]
            .try_into()
            .map_err(|_| CoreError::Crypto("Invalid Ed25519 signing key bytes".into()))?;

        let private = StaticSecret::from(x25519_bytes);
        let public = PublicKey::from(&private);
        let signing_key = SigningKey::from_bytes(&ed25519_bytes);

        Ok(Self {
            private,
            public,
            signing_key,
        })
    }
}

impl EphemeralKeyPair {
    /// Generate a fresh ephemeral X25519 key pair.
    pub fn generate() -> Self {
        let private = StaticSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&private);
        Self { private, public }
    }
}

impl PreKeyBundle {
    /// Verify the signed prekey signature against the identity key's Ed25519 public key.
    pub fn verify_signature(&self, verifying_key: &VerifyingKey) -> Result<(), CoreError> {
        verifying_key
            .verify(self.signed_prekey.as_bytes(), &self.signed_prekey_signature)
            .map_err(|e| CoreError::Crypto(format!("Signed prekey signature invalid: {e}")))
    }

    /// Serialize the prekey bundle to bytes for wire transport.
    ///
    /// Layout:
    /// - identity_key (32)
    /// - signed_prekey (32)
    /// - signature (64)
    /// - has_otp (1)
    /// - one_time_prekey (32, if present)
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(129 + 32);
        out.extend_from_slice(self.identity_key.as_bytes());
        out.extend_from_slice(self.signed_prekey.as_bytes());
        out.extend_from_slice(&self.signed_prekey_signature.to_bytes());
        if let Some(ref otk) = self.one_time_prekey {
            out.push(1);
            out.extend_from_slice(otk.as_bytes());
        } else {
            out.push(0);
        }
        out
    }

    /// Deserialize a prekey bundle from bytes.
    pub fn deserialize(data: &[u8]) -> Result<Self, CoreError> {
        if data.len() < 129 {
            return Err(CoreError::Crypto(
                "PreKeyBundle data too short (need >= 129 bytes)".into(),
            ));
        }

        let identity_bytes: [u8; 32] = data[..32]
            .try_into()
            .map_err(|_| CoreError::Crypto("Invalid identity key".into()))?;
        let spk_bytes: [u8; 32] = data[32..64]
            .try_into()
            .map_err(|_| CoreError::Crypto("Invalid signed prekey".into()))?;
        let sig_bytes: [u8; 64] = data[64..128]
            .try_into()
            .map_err(|_| CoreError::Crypto("Invalid signature".into()))?;
        let has_otp = data[128];

        let one_time_prekey = if has_otp == 1 {
            if data.len() < 161 {
                return Err(CoreError::Crypto(
                    "PreKeyBundle data too short for one-time prekey".into(),
                ));
            }
            let otp_bytes: [u8; 32] = data[129..161]
                .try_into()
                .map_err(|_| CoreError::Crypto("Invalid one-time prekey".into()))?;
            Some(PublicKey::from(otp_bytes))
        } else {
            None
        };

        Ok(Self {
            identity_key: PublicKey::from(identity_bytes),
            signed_prekey: PublicKey::from(spk_bytes),
            signed_prekey_signature: ed25519_dalek::Signature::from_bytes(&sig_bytes),
            one_time_prekey,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_identity_keypair_generate() {
        let kp = IdentityKeyPair::generate();
        // Public key should be derivable from private
        let expected_pub = PublicKey::from(&kp.private);
        assert_eq!(kp.public.as_bytes(), expected_pub.as_bytes());
    }

    #[test]
    fn test_identity_keypair_serialize_roundtrip() {
        let kp = IdentityKeyPair::generate();
        let serialized = kp.serialize();
        assert_eq!(serialized.len(), 64);

        let kp2 = IdentityKeyPair::deserialize(&serialized).unwrap();
        assert_eq!(kp.public.as_bytes(), kp2.public.as_bytes());
        assert_eq!(
            kp.signing_key.verifying_key().as_bytes(),
            kp2.signing_key.verifying_key().as_bytes()
        );
    }

    #[test]
    fn test_identity_keypair_deserialize_too_short() {
        let result = IdentityKeyPair::deserialize(&[0u8; 32]);
        assert!(result.is_err());
    }

    #[test]
    fn test_ephemeral_keypair_generate() {
        let ek = EphemeralKeyPair::generate();
        let expected_pub = PublicKey::from(&ek.private);
        assert_eq!(ek.public.as_bytes(), expected_pub.as_bytes());
    }

    #[test]
    fn test_prekey_bundle_serialize_roundtrip_with_otp() {
        let identity = IdentityKeyPair::generate();
        let spk_secret = StaticSecret::random_from_rng(OsRng);
        let spk_public = PublicKey::from(&spk_secret);
        let signature = identity.sign(spk_public.as_bytes());

        let otp_secret = StaticSecret::random_from_rng(OsRng);
        let otp_public = PublicKey::from(&otp_secret);

        let bundle = PreKeyBundle {
            identity_key: identity.public,
            signed_prekey: spk_public,
            signed_prekey_signature: signature,
            one_time_prekey: Some(otp_public),
        };

        let data = bundle.serialize();
        assert_eq!(data.len(), 161);

        let bundle2 = PreKeyBundle::deserialize(&data).unwrap();
        assert_eq!(
            bundle.identity_key.as_bytes(),
            bundle2.identity_key.as_bytes()
        );
        assert_eq!(
            bundle.signed_prekey.as_bytes(),
            bundle2.signed_prekey.as_bytes()
        );
        assert!(bundle2.one_time_prekey.is_some());
        assert_eq!(
            bundle.one_time_prekey.unwrap().as_bytes(),
            bundle2.one_time_prekey.unwrap().as_bytes()
        );
    }

    #[test]
    fn test_prekey_bundle_serialize_roundtrip_without_otp() {
        let identity = IdentityKeyPair::generate();
        let spk_secret = StaticSecret::random_from_rng(OsRng);
        let spk_public = PublicKey::from(&spk_secret);
        let signature = identity.sign(spk_public.as_bytes());

        let bundle = PreKeyBundle {
            identity_key: identity.public,
            signed_prekey: spk_public,
            signed_prekey_signature: signature,
            one_time_prekey: None,
        };

        let data = bundle.serialize();
        assert_eq!(data.len(), 129);

        let bundle2 = PreKeyBundle::deserialize(&data).unwrap();
        assert!(bundle2.one_time_prekey.is_none());
    }

    #[test]
    fn test_prekey_bundle_verify_signature_valid() {
        let identity = IdentityKeyPair::generate();
        let spk_secret = StaticSecret::random_from_rng(OsRng);
        let spk_public = PublicKey::from(&spk_secret);
        let signature = identity.sign(spk_public.as_bytes());

        let bundle = PreKeyBundle {
            identity_key: identity.public,
            signed_prekey: spk_public,
            signed_prekey_signature: signature,
            one_time_prekey: None,
        };

        assert!(bundle.verify_signature(&identity.verifying_key()).is_ok());
    }

    #[test]
    fn test_prekey_bundle_verify_signature_invalid() {
        let identity = IdentityKeyPair::generate();
        let evil = IdentityKeyPair::generate();
        let spk_secret = StaticSecret::random_from_rng(OsRng);
        let spk_public = PublicKey::from(&spk_secret);
        // Signed by evil, not by identity
        let signature = evil.sign(spk_public.as_bytes());

        let bundle = PreKeyBundle {
            identity_key: identity.public,
            signed_prekey: spk_public,
            signed_prekey_signature: signature,
            one_time_prekey: None,
        };

        assert!(bundle.verify_signature(&identity.verifying_key()).is_err());
    }
}
