//! High-level session management for the Signal Protocol.
//!
//! Provides the public API used by the Flutter client (via FFI) to create
//! encrypted sessions and send/receive messages with per-message forward secrecy.

use x25519_dalek::{PublicKey, StaticSecret};

use super::keys::{IdentityKeyPair, PreKeyBundle};
use super::ratchet::{MessageHeader, RatchetState};
use super::x3dh;
use crate::error::CoreError;

/// An established (or pending) encrypted session with a peer.
pub struct Session {
    /// Identifier of the remote peer.
    pub peer_user_id: String,
    /// Double Ratchet state for this session.
    pub ratchet: RatchetState,
    /// Whether the session has completed its initial handshake.
    pub established: bool,
}

// Wire format for an encrypted message:
//
// Layout:
// - header_len (4 LE)
// - header (variable)
// - ciphertext (remainder)
//
// The header contains the sender's current ratchet public key and counters.
// The ciphertext contains the AES-GCM-encrypted payload (nonce || ct || tag).

/// Alice creates a new session with Bob using his prekey bundle.
///
/// Returns the session and an initial message blob that must be sent to Bob
/// so he can initialize his side. The initial message contains Alice's
/// ephemeral public key, identity public key, and the (optional) one-time
/// prekey indicator needed for Bob to compute the same shared secret.
pub fn create_session(
    my_keys: &IdentityKeyPair,
    peer_user_id: &str,
    peer_bundle: &PreKeyBundle,
    peer_verifying_key: &ed25519_dalek::VerifyingKey,
) -> Result<(Session, Vec<u8>), CoreError> {
    // Perform X3DH to derive shared secret
    let x3dh_result = x3dh::initiate(my_keys, peer_bundle, peer_verifying_key)?;

    // Initialize Double Ratchet as Alice
    // Bob's signed prekey serves as his initial ratchet public key
    let ratchet = RatchetState::init_alice(&x3dh_result.shared_secret, &peer_bundle.signed_prekey)?;

    let session = Session {
        peer_user_id: peer_user_id.to_string(),
        ratchet,
        established: true,
    };

    // Build the initial message: Alice's identity + ephemeral public keys
    // so Bob can compute the same X3DH shared secret.
    //
    // Layout:
    // - alice_identity_public (32)
    // - alice_ephemeral_public (32)
    // - has_one_time_prekey (1)
    // - one_time_prekey (32, if present) -- tells Bob which OTP was used
    let mut initial_msg = Vec::with_capacity(97);
    initial_msg.extend_from_slice(my_keys.public.as_bytes());
    initial_msg.extend_from_slice(x3dh_result.ephemeral_public.as_bytes());
    if let Some(ref otp) = peer_bundle.one_time_prekey {
        initial_msg.push(1);
        initial_msg.extend_from_slice(otp.as_bytes());
    } else {
        initial_msg.push(0);
    }

    Ok((session, initial_msg))
}

/// Bob receives Alice's initial message and creates his side of the session.
///
/// `initial_msg` is the blob produced by `create_session` on Alice's side.
/// Bob needs his identity key pair, signed prekey private, and (optionally)
/// the one-time prekey private that Alice consumed.
pub fn accept_session(
    my_keys: &IdentityKeyPair,
    my_signed_prekey_private: &StaticSecret,
    my_one_time_prekey_private: Option<&StaticSecret>,
    peer_user_id: &str,
    initial_msg: &[u8],
) -> Result<Session, CoreError> {
    // Parse Alice's initial message
    if initial_msg.len() < 65 {
        return Err(CoreError::Crypto(
            "Initial message too short (need >= 65 bytes)".into(),
        ));
    }

    let alice_identity_bytes: [u8; 32] = initial_msg[..32]
        .try_into()
        .map_err(|_| CoreError::Crypto("Invalid identity key in initial message".into()))?;
    let alice_ephemeral_bytes: [u8; 32] = initial_msg[32..64]
        .try_into()
        .map_err(|_| CoreError::Crypto("Invalid ephemeral key in initial message".into()))?;

    let alice_identity_public = PublicKey::from(alice_identity_bytes);
    let alice_ephemeral_public = PublicKey::from(alice_ephemeral_bytes);

    let _has_otp = initial_msg[64];
    // Note: The has_otp flag tells Bob which one-time prekey Alice used.
    // The caller is responsible for looking up the correct OTP private key
    // and passing it as `my_one_time_prekey_private`.

    // Perform X3DH as responder
    let shared_secret = x3dh::respond(
        my_keys,
        my_signed_prekey_private,
        my_one_time_prekey_private,
        &alice_identity_public,
        &alice_ephemeral_public,
    )?;

    // Initialize Double Ratchet as Bob
    // Clone the signed prekey private for the ratchet (Bob's initial ratchet key)
    let bob_ratchet_private = StaticSecret::from(my_signed_prekey_private.to_bytes());
    let ratchet = RatchetState::init_bob(&shared_secret, bob_ratchet_private)?;

    Ok(Session {
        peer_user_id: peer_user_id.to_string(),
        ratchet,
        established: true,
    })
}

/// Encrypt a plaintext message within an established session.
///
/// Returns a self-contained encrypted message blob (header + ciphertext)
/// that can be sent over the wire.
pub fn encrypt_message(session: &mut Session, plaintext: &[u8]) -> Result<Vec<u8>, CoreError> {
    if !session.established {
        return Err(CoreError::Crypto("Session not established".into()));
    }

    let (ciphertext, header) = session.ratchet.encrypt(plaintext)?;
    let header_bytes = header.serialize();

    // Wire format: header_len (4 LE) || header || ciphertext
    let header_len = header_bytes.len() as u32;
    let mut wire = Vec::with_capacity(4 + header_bytes.len() + ciphertext.len());
    wire.extend_from_slice(&header_len.to_le_bytes());
    wire.extend_from_slice(&header_bytes);
    wire.extend_from_slice(&ciphertext);

    Ok(wire)
}

/// Decrypt an encrypted message blob received from a peer.
///
/// The input should be in the wire format produced by `encrypt_message`.
pub fn decrypt_message(session: &mut Session, data: &[u8]) -> Result<Vec<u8>, CoreError> {
    if !session.established {
        return Err(CoreError::Crypto("Session not established".into()));
    }

    if data.len() < 4 {
        return Err(CoreError::Crypto("Encrypted message too short".into()));
    }

    let header_len = u32::from_le_bytes(
        data[..4]
            .try_into()
            .map_err(|_| CoreError::Crypto("Invalid header length".into()))?,
    ) as usize;

    if data.len() < 4 + header_len {
        return Err(CoreError::Crypto(
            "Encrypted message shorter than declared header".into(),
        ));
    }

    let header = MessageHeader::deserialize(&data[4..4 + header_len])?;
    let ciphertext = &data[4 + header_len..];

    session.ratchet.decrypt(&header, ciphertext)
}

/// Serialize a session for persistent storage.
///
/// Layout: peer_user_id_len (4 LE) || peer_user_id (UTF-8) || established (1) || ratchet_state
pub fn serialize_session(session: &Session) -> Vec<u8> {
    let peer_bytes = session.peer_user_id.as_bytes();
    let ratchet_bytes = session.ratchet.serialize();

    let mut out = Vec::with_capacity(4 + peer_bytes.len() + 1 + ratchet_bytes.len());
    out.extend_from_slice(&(peer_bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(peer_bytes);
    out.push(u8::from(session.established));
    out.extend_from_slice(&ratchet_bytes);
    out
}

/// Deserialize a session from bytes produced by [`serialize_session`].
pub fn deserialize_session(data: &[u8]) -> Result<Session, CoreError> {
    if data.len() < 5 {
        return Err(CoreError::Crypto("Session data too short".into()));
    }

    let peer_len = u32::from_le_bytes(
        data[..4]
            .try_into()
            .map_err(|_| CoreError::Crypto("Invalid peer_user_id length".into()))?,
    ) as usize;

    if data.len() < 4 + peer_len + 1 {
        return Err(CoreError::Crypto(
            "Session data too short for peer_id".into(),
        ));
    }

    let peer_user_id = String::from_utf8(data[4..4 + peer_len].to_vec())
        .map_err(|e| CoreError::Crypto(format!("Invalid UTF-8 in peer_user_id: {e}")))?;

    let established = data[4 + peer_len] != 0;
    let ratchet = RatchetState::deserialize(&data[4 + peer_len + 1..])?;

    Ok(Session {
        peer_user_id,
        ratchet,
        established,
    })
}

#[cfg(test)]
mod tests {
    use super::super::keys::IdentityKeyPair;
    use super::*;
    use rand_core::OsRng;
    use x25519_dalek::StaticSecret;

    /// Set up Alice and Bob identities, Bob's prekey bundle, and all secrets.
    fn full_setup() -> (
        IdentityKeyPair,
        IdentityKeyPair,
        PreKeyBundle,
        StaticSecret,
        Option<StaticSecret>,
    ) {
        let alice_identity = IdentityKeyPair::generate();
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
            alice_identity,
            bob_identity,
            bundle,
            bob_spk_private,
            Some(bob_otp_private),
        )
    }

    #[test]
    fn test_full_session_flow() {
        let (alice_id, bob_id, bundle, bob_spk_priv, bob_otp_priv) = full_setup();

        let bob_verifying = bob_id.verifying_key();

        // Alice creates session
        let (mut alice_session, initial_msg) =
            create_session(&alice_id, "bob-123", &bundle, &bob_verifying).unwrap();

        // Bob accepts session
        let mut bob_session = accept_session(
            &bob_id,
            &bob_spk_priv,
            bob_otp_priv.as_ref(),
            "alice-456",
            &initial_msg,
        )
        .unwrap();

        assert!(alice_session.established);
        assert!(bob_session.established);

        // Alice -> Bob
        let wire = encrypt_message(&mut alice_session, b"Hello Bob!").unwrap();
        let pt = decrypt_message(&mut bob_session, &wire).unwrap();
        assert_eq!(pt, b"Hello Bob!");

        // Bob -> Alice
        let wire = encrypt_message(&mut bob_session, b"Hello Alice!").unwrap();
        let pt = decrypt_message(&mut alice_session, &wire).unwrap();
        assert_eq!(pt, b"Hello Alice!");
    }

    #[test]
    fn test_session_multiple_roundtrips() {
        let (alice_id, bob_id, bundle, bob_spk_priv, bob_otp_priv) = full_setup();
        let bob_verifying = bob_id.verifying_key();

        let (mut alice_session, initial_msg) =
            create_session(&alice_id, "bob", &bundle, &bob_verifying).unwrap();
        let mut bob_session = accept_session(
            &bob_id,
            &bob_spk_priv,
            bob_otp_priv.as_ref(),
            "alice",
            &initial_msg,
        )
        .unwrap();

        for i in 0..20 {
            let msg_ab = format!("Alice to Bob {i}");
            let wire = encrypt_message(&mut alice_session, msg_ab.as_bytes()).unwrap();
            let pt = decrypt_message(&mut bob_session, &wire).unwrap();
            assert_eq!(pt, msg_ab.as_bytes());

            let msg_ba = format!("Bob to Alice {i}");
            let wire = encrypt_message(&mut bob_session, msg_ba.as_bytes()).unwrap();
            let pt = decrypt_message(&mut alice_session, &wire).unwrap();
            assert_eq!(pt, msg_ba.as_bytes());
        }
    }

    #[test]
    fn test_session_without_one_time_prekey() {
        let alice_identity = IdentityKeyPair::generate();
        let bob_identity = IdentityKeyPair::generate();

        let bob_spk_private = StaticSecret::random_from_rng(OsRng);
        let bob_spk_public = PublicKey::from(&bob_spk_private);
        let spk_sig = bob_identity.sign(bob_spk_public.as_bytes());

        let bundle = PreKeyBundle {
            identity_key: bob_identity.public,
            signed_prekey: bob_spk_public,
            signed_prekey_signature: spk_sig,
            one_time_prekey: None,
        };

        let bob_verifying = bob_identity.verifying_key();
        let (mut alice_session, initial_msg) =
            create_session(&alice_identity, "bob", &bundle, &bob_verifying).unwrap();
        let mut bob_session =
            accept_session(&bob_identity, &bob_spk_private, None, "alice", &initial_msg).unwrap();

        let wire = encrypt_message(&mut alice_session, b"no OTP").unwrap();
        let pt = decrypt_message(&mut bob_session, &wire).unwrap();
        assert_eq!(pt, b"no OTP");
    }

    #[test]
    fn test_session_serialize_deserialize() {
        let (alice_id, bob_id, bundle, bob_spk_priv, bob_otp_priv) = full_setup();
        let bob_verifying = bob_id.verifying_key();

        let (mut alice_session, initial_msg) =
            create_session(&alice_id, "bob-xyz", &bundle, &bob_verifying).unwrap();
        let mut bob_session = accept_session(
            &bob_id,
            &bob_spk_priv,
            bob_otp_priv.as_ref(),
            "alice-abc",
            &initial_msg,
        )
        .unwrap();

        // Exchange a message
        let wire = encrypt_message(&mut alice_session, b"pre-serialize").unwrap();
        let _ = decrypt_message(&mut bob_session, &wire).unwrap();

        // Serialize both sessions
        let alice_bytes = serialize_session(&alice_session);
        let bob_bytes = serialize_session(&bob_session);

        // Deserialize
        let mut alice2 = deserialize_session(&alice_bytes).unwrap();
        let mut bob2 = deserialize_session(&bob_bytes).unwrap();

        assert_eq!(alice2.peer_user_id, "bob-xyz");
        assert_eq!(bob2.peer_user_id, "alice-abc");
        assert!(alice2.established);
        assert!(bob2.established);

        // Continue the conversation
        let wire = encrypt_message(&mut alice2, b"post-serialize").unwrap();
        let pt = decrypt_message(&mut bob2, &wire).unwrap();
        assert_eq!(pt, b"post-serialize");
    }

    #[test]
    fn test_decrypt_unestablished_session_fails() {
        let shared_secret = [0u8; 32];
        let dummy_priv = StaticSecret::random_from_rng(OsRng);
        let ratchet = RatchetState::init_bob(&shared_secret, dummy_priv).unwrap();

        let mut session = Session {
            peer_user_id: "test".into(),
            ratchet,
            established: false,
        };

        let result = encrypt_message(&mut session, b"test");
        assert!(result.is_err());
    }

    #[test]
    fn test_decrypt_message_too_short() {
        let (alice_id, bob_id, bundle, bob_spk_priv, bob_otp_priv) = full_setup();
        let bob_verifying = bob_id.verifying_key();

        let (_, initial_msg) = create_session(&alice_id, "bob", &bundle, &bob_verifying).unwrap();
        let mut bob_session = accept_session(
            &bob_id,
            &bob_spk_priv,
            bob_otp_priv.as_ref(),
            "alice",
            &initial_msg,
        )
        .unwrap();

        let result = decrypt_message(&mut bob_session, &[0, 0]);
        assert!(result.is_err());
    }
}
