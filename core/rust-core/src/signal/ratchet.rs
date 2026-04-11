//! Double Ratchet Algorithm for per-message forward secrecy.
//!
//! Implements the Signal Protocol Double Ratchet as specified at:
//! <https://signal.org/docs/specifications/doubleratchet/>
//!
//! Each message gets a unique encryption key derived from a chain key.
//! A DH ratchet step occurs whenever a new ratchet public key is received,
//! providing forward secrecy and break-in recovery.

use std::collections::HashMap;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::error::CoreError;

/// Maximum number of skipped message keys to store (prevents memory exhaustion
/// from a malicious peer sending huge message numbers).
const MAX_SKIP: u32 = 1000;

/// HKDF info strings for key derivation.
const RATCHET_KDF_INFO: &[u8] = b"EchoDoubleRatchet";
const CHAIN_KEY_SEED: u8 = 0x02;
const MESSAGE_KEY_SEED: u8 = 0x01;

/// Header attached to each encrypted message.
///
/// Contains the sender's current ratchet public key and counters needed
/// for the receiver to synchronize their ratchet state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageHeader {
    /// Sender's current DH ratchet public key.
    pub ratchet_public_key: [u8; 32],
    /// Number of messages sent in the previous sending chain.
    pub prev_chain_length: u32,
    /// Message number within the current sending chain.
    pub message_number: u32,
}

impl MessageHeader {
    /// Serialize header to bytes.
    ///
    /// Layout: ratchet_public_key (32) || prev_chain_length (4 LE) || message_number (4 LE)
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(40);
        out.extend_from_slice(&self.ratchet_public_key);
        out.extend_from_slice(&self.prev_chain_length.to_le_bytes());
        out.extend_from_slice(&self.message_number.to_le_bytes());
        out
    }

    /// Deserialize header from bytes.
    pub fn deserialize(data: &[u8]) -> Result<Self, CoreError> {
        if data.len() < 40 {
            return Err(CoreError::Crypto(
                "MessageHeader data too short (need 40 bytes)".into(),
            ));
        }

        let mut ratchet_public_key = [0u8; 32];
        ratchet_public_key.copy_from_slice(&data[..32]);

        let prev_chain_length = u32::from_le_bytes(
            data[32..36]
                .try_into()
                .map_err(|_| CoreError::Crypto("Invalid prev_chain_length".into()))?,
        );
        let message_number = u32::from_le_bytes(
            data[36..40]
                .try_into()
                .map_err(|_| CoreError::Crypto("Invalid message_number".into()))?,
        );

        Ok(Self {
            ratchet_public_key,
            prev_chain_length,
            message_number,
        })
    }
}

/// The Double Ratchet state for one direction of a conversation.
pub struct RatchetState {
    /// Root key -- evolves with each DH ratchet step.
    root_key: [u8; 32],
    /// Current sending chain key.
    sending_chain_key: [u8; 32],
    /// Current receiving chain key (None until first message received).
    receiving_chain_key: Option<[u8; 32]>,
    /// Our current DH ratchet private key.
    sending_ratchet_private: StaticSecret,
    /// Our current DH ratchet public key.
    sending_ratchet_public: PublicKey,
    /// Peer's current DH ratchet public key (None until first message received).
    receiving_ratchet_key: Option<PublicKey>,
    /// Number of messages sent in the current sending chain.
    send_counter: u32,
    /// Number of messages received in the current receiving chain.
    recv_counter: u32,
    /// Number of messages sent in the previous sending chain (for header).
    prev_send_counter: u32,
    /// Skipped message keys, keyed by (ratchet_public_key_bytes, message_number).
    /// These allow decrypting out-of-order messages.
    skipped_keys: HashMap<([u8; 32], u32), [u8; 32]>,
}

/// Perform a KDF on root_key + DH output to produce new (root_key, chain_key).
///
/// Uses HKDF-SHA256 with the current root key as salt and the DH shared
/// secret as input keying material. Outputs 64 bytes: first 32 are the
/// new root key, last 32 are the new chain key.
fn kdf_rk(root_key: &[u8; 32], dh_output: &[u8; 32]) -> Result<([u8; 32], [u8; 32]), CoreError> {
    let hk = Hkdf::<Sha256>::new(Some(root_key), dh_output);
    let mut okm = [0u8; 64];
    hk.expand(RATCHET_KDF_INFO, &mut okm)
        .map_err(|e| CoreError::Crypto(format!("KDF-RK expand failed: {e}")))?;

    let mut new_root = [0u8; 32];
    let mut new_chain = [0u8; 32];
    new_root.copy_from_slice(&okm[..32]);
    new_chain.copy_from_slice(&okm[32..64]);
    Ok((new_root, new_chain))
}

/// Derive a message key from a chain key and advance the chain.
///
/// Returns (new_chain_key, message_key).
/// - chain_key_next = HKDF(chain_key, CHAIN_KEY_SEED)
/// - message_key    = HKDF(chain_key, MESSAGE_KEY_SEED)
fn kdf_ck(chain_key: &[u8; 32]) -> Result<([u8; 32], [u8; 32]), CoreError> {
    // Derive message key
    let hk_mk = Hkdf::<Sha256>::new(Some(chain_key), &[MESSAGE_KEY_SEED]);
    let mut message_key = [0u8; 32];
    hk_mk
        .expand(b"EchoMessageKey", &mut message_key)
        .map_err(|e| CoreError::Crypto(format!("KDF-CK message key failed: {e}")))?;

    // Derive next chain key
    let hk_ck = Hkdf::<Sha256>::new(Some(chain_key), &[CHAIN_KEY_SEED]);
    let mut next_chain_key = [0u8; 32];
    hk_ck
        .expand(b"EchoChainKey", &mut next_chain_key)
        .map_err(|e| CoreError::Crypto(format!("KDF-CK chain key failed: {e}")))?;

    Ok((next_chain_key, message_key))
}

/// Encrypt plaintext with AES-256-GCM using the given key, with the header
/// serialized as associated data (AAD) to bind the ciphertext to the header.
fn encrypt_with_ad(key: &[u8; 32], plaintext: &[u8], ad: &[u8]) -> Result<Vec<u8>, CoreError> {
    let cipher_key = Key::<Aes256Gcm>::from_slice(key);
    let cipher = Aes256Gcm::new(cipher_key);

    let mut nonce_bytes = [0u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let payload = aes_gcm::aead::Payload {
        msg: plaintext,
        aad: ad,
    };

    let ciphertext = cipher
        .encrypt(nonce, payload)
        .map_err(|e| CoreError::Crypto(format!("AES-GCM encrypt failed: {e}")))?;

    // Return nonce || ciphertext (includes tag)
    let mut result = Vec::with_capacity(12 + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

/// Decrypt ciphertext with AES-256-GCM, verifying the associated data.
fn decrypt_with_ad(key: &[u8; 32], ciphertext: &[u8], ad: &[u8]) -> Result<Vec<u8>, CoreError> {
    if ciphertext.len() < 12 + 16 {
        return Err(CoreError::Crypto(
            "Ciphertext too short for AES-GCM (need >= 28 bytes)".into(),
        ));
    }

    let (nonce_bytes, ct) = ciphertext.split_at(12);
    let nonce = Nonce::from_slice(nonce_bytes);

    let cipher_key = Key::<Aes256Gcm>::from_slice(key);
    let cipher = Aes256Gcm::new(cipher_key);

    let payload = aes_gcm::aead::Payload { msg: ct, aad: ad };

    cipher
        .decrypt(nonce, payload)
        .map_err(|e| CoreError::Crypto(format!("AES-GCM decrypt failed: {e}")))
}

impl RatchetState {
    /// Initialize the ratchet as Alice (the session initiator).
    ///
    /// Alice has performed X3DH and knows the shared secret. She also knows
    /// Bob's signed prekey (which serves as his initial ratchet public key).
    /// Alice immediately performs a DH ratchet step to establish her sending chain.
    pub fn init_alice(
        shared_secret: &[u8; 32],
        bob_ratchet_public: &PublicKey,
    ) -> Result<Self, CoreError> {
        // Generate Alice's first ratchet key pair
        let sending_ratchet_private = StaticSecret::random_from_rng(OsRng);
        let sending_ratchet_public = PublicKey::from(&sending_ratchet_private);

        // Perform the initial DH ratchet step
        let dh_output = sending_ratchet_private.diffie_hellman(bob_ratchet_public);
        let (root_key, sending_chain_key) = kdf_rk(shared_secret, dh_output.as_bytes())?;

        Ok(Self {
            root_key,
            sending_chain_key,
            receiving_chain_key: None,
            sending_ratchet_private,
            sending_ratchet_public,
            receiving_ratchet_key: Some(*bob_ratchet_public),
            send_counter: 0,
            recv_counter: 0,
            prev_send_counter: 0,
            skipped_keys: HashMap::new(),
        })
    }

    /// Initialize the ratchet as Bob (the session responder).
    ///
    /// Bob uses his signed prekey as the initial ratchet key pair. He does
    /// not perform a DH ratchet step until he receives Alice's first message.
    pub fn init_bob(
        shared_secret: &[u8; 32],
        bob_ratchet_private: StaticSecret,
    ) -> Result<Self, CoreError> {
        let bob_ratchet_public = PublicKey::from(&bob_ratchet_private);

        Ok(Self {
            root_key: *shared_secret,
            sending_chain_key: [0u8; 32], // Not used until first DH ratchet step
            receiving_chain_key: None,
            sending_ratchet_private: bob_ratchet_private,
            sending_ratchet_public: bob_ratchet_public,
            receiving_ratchet_key: None,
            send_counter: 0,
            recv_counter: 0,
            prev_send_counter: 0,
            skipped_keys: HashMap::new(),
        })
    }

    /// Encrypt a plaintext message.
    ///
    /// Advances the sending chain, derives a message key, encrypts the
    /// plaintext with AES-256-GCM, and returns the ciphertext + header.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<(Vec<u8>, MessageHeader), CoreError> {
        // Derive message key and advance chain
        let (new_chain_key, message_key) = kdf_ck(&self.sending_chain_key)?;
        self.sending_chain_key = new_chain_key;

        let header = MessageHeader {
            ratchet_public_key: *self.sending_ratchet_public.as_bytes(),
            prev_chain_length: self.prev_send_counter,
            message_number: self.send_counter,
        };

        self.send_counter += 1;

        let ad = header.serialize();
        let ciphertext = encrypt_with_ad(&message_key, plaintext, &ad)?;

        Ok((ciphertext, header))
    }

    /// Decrypt a received message.
    ///
    /// If the header contains a new ratchet public key, performs a DH ratchet
    /// step first. Handles out-of-order messages by checking skipped keys.
    pub fn decrypt(
        &mut self,
        header: &MessageHeader,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>, CoreError> {
        // Check if we have a skipped message key for this (ratchet_key, message_number)
        let ad = header.serialize();
        if let Some(message_key) = self
            .skipped_keys
            .remove(&(header.ratchet_public_key, header.message_number))
        {
            return decrypt_with_ad(&message_key, ciphertext, &ad);
        }

        let header_ratchet_pub = PublicKey::from(header.ratchet_public_key);

        // Check if we need a DH ratchet step
        let need_dh_ratchet = match &self.receiving_ratchet_key {
            None => true,
            Some(current) => current.as_bytes() != &header.ratchet_public_key,
        };

        if need_dh_ratchet {
            // Skip any remaining messages in the current receiving chain
            if self.receiving_chain_key.is_some() {
                self.skip_message_keys(header.prev_chain_length)?;
            }

            self.dh_ratchet_step(&header_ratchet_pub)?;
        }

        // Skip ahead to the message number if needed
        self.skip_message_keys(header.message_number)?;

        // Derive message key and advance receiving chain
        let receiving_chain = self
            .receiving_chain_key
            .as_ref()
            .ok_or_else(|| CoreError::Crypto("No receiving chain key".into()))?;

        let (new_chain_key, message_key) = kdf_ck(receiving_chain)?;
        self.receiving_chain_key = Some(new_chain_key);
        self.recv_counter += 1;

        decrypt_with_ad(&message_key, ciphertext, &ad)
    }

    /// Perform a DH ratchet step with a new peer ratchet public key.
    fn dh_ratchet_step(&mut self, new_peer_ratchet_key: &PublicKey) -> Result<(), CoreError> {
        self.prev_send_counter = self.send_counter;
        self.send_counter = 0;
        self.recv_counter = 0;

        self.receiving_ratchet_key = Some(*new_peer_ratchet_key);

        // Derive new receiving chain from DH(our_current_private, their_new_public)
        let dh_recv = self
            .sending_ratchet_private
            .diffie_hellman(new_peer_ratchet_key);
        let (root_key, receiving_chain_key) = kdf_rk(&self.root_key, dh_recv.as_bytes())?;
        self.root_key = root_key;
        self.receiving_chain_key = Some(receiving_chain_key);

        // Generate new sending ratchet key pair
        self.sending_ratchet_private = StaticSecret::random_from_rng(OsRng);
        self.sending_ratchet_public = PublicKey::from(&self.sending_ratchet_private);

        // Derive new sending chain
        let dh_send = self
            .sending_ratchet_private
            .diffie_hellman(new_peer_ratchet_key);
        let (root_key, sending_chain_key) = kdf_rk(&self.root_key, dh_send.as_bytes())?;
        self.root_key = root_key;
        self.sending_chain_key = sending_chain_key;

        Ok(())
    }

    /// Skip message keys up to (but not including) the target message number.
    ///
    /// Stores the skipped keys so out-of-order messages can still be decrypted.
    fn skip_message_keys(&mut self, until: u32) -> Result<(), CoreError> {
        if self.recv_counter + MAX_SKIP < until {
            return Err(CoreError::Crypto(format!(
                "Too many skipped messages (recv_counter={}, target={})",
                self.recv_counter, until,
            )));
        }

        if let Some(ref mut chain_key) = self.receiving_chain_key {
            while self.recv_counter < until {
                let (new_ck, mk) = kdf_ck(chain_key)?;
                let rk = self
                    .receiving_ratchet_key
                    .as_ref()
                    .map(|k| *k.as_bytes())
                    .unwrap_or([0u8; 32]);
                self.skipped_keys.insert((rk, self.recv_counter), mk);
                *chain_key = new_ck;
                self.recv_counter += 1;
            }
        }

        Ok(())
    }

    /// Serialize the ratchet state to bytes for persistent storage.
    ///
    /// Layout (all fixed-size fields, then variable-length skipped keys):
    /// - root_key (32)
    /// - sending_chain_key (32)
    /// - has_receiving_chain_key (1) + receiving_chain_key (32, if present)
    /// - sending_ratchet_private (32)
    /// - sending_ratchet_public (32)
    /// - has_receiving_ratchet_key (1) + receiving_ratchet_key (32, if present)
    /// - send_counter (4 LE)
    /// - recv_counter (4 LE)
    /// - prev_send_counter (4 LE)
    /// - num_skipped_keys (4 LE)
    /// - for each skipped key: ratchet_public (32) + msg_num (4 LE) + key (32)
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(256);

        out.extend_from_slice(&self.root_key);
        out.extend_from_slice(&self.sending_chain_key);

        if let Some(ref rck) = self.receiving_chain_key {
            out.push(1);
            out.extend_from_slice(rck);
        } else {
            out.push(0);
        }

        out.extend_from_slice(&self.sending_ratchet_private.to_bytes());
        out.extend_from_slice(self.sending_ratchet_public.as_bytes());

        if let Some(ref rrk) = self.receiving_ratchet_key {
            out.push(1);
            out.extend_from_slice(rrk.as_bytes());
        } else {
            out.push(0);
        }

        out.extend_from_slice(&self.send_counter.to_le_bytes());
        out.extend_from_slice(&self.recv_counter.to_le_bytes());
        out.extend_from_slice(&self.prev_send_counter.to_le_bytes());

        let num_skipped = self.skipped_keys.len() as u32;
        out.extend_from_slice(&num_skipped.to_le_bytes());
        for ((rk, msg_num), key) in &self.skipped_keys {
            out.extend_from_slice(rk);
            out.extend_from_slice(&msg_num.to_le_bytes());
            out.extend_from_slice(key);
        }

        out
    }

    /// Deserialize ratchet state from bytes produced by [`serialize`].
    pub fn deserialize(data: &[u8]) -> Result<Self, CoreError> {
        let err = |msg: &str| CoreError::Crypto(format!("RatchetState deserialize: {msg}"));
        let mut pos = 0;

        fn read_32(data: &[u8], pos: &mut usize) -> Result<[u8; 32], CoreError> {
            if *pos + 32 > data.len() {
                return Err(CoreError::Crypto(
                    "RatchetState deserialize: unexpected EOF".into(),
                ));
            }
            let mut buf = [0u8; 32];
            buf.copy_from_slice(&data[*pos..*pos + 32]);
            *pos += 32;
            Ok(buf)
        }

        fn read_u32(data: &[u8], pos: &mut usize) -> Result<u32, CoreError> {
            if *pos + 4 > data.len() {
                return Err(CoreError::Crypto(
                    "RatchetState deserialize: unexpected EOF".into(),
                ));
            }
            let val = u32::from_le_bytes(
                data[*pos..*pos + 4]
                    .try_into()
                    .map_err(|_| CoreError::Crypto("Bad u32".into()))?,
            );
            *pos += 4;
            Ok(val)
        }

        fn read_u8(data: &[u8], pos: &mut usize) -> Result<u8, CoreError> {
            if *pos >= data.len() {
                return Err(CoreError::Crypto(
                    "RatchetState deserialize: unexpected EOF".into(),
                ));
            }
            let val = data[*pos];
            *pos += 1;
            Ok(val)
        }

        let root_key = read_32(data, &mut pos)?;
        let sending_chain_key = read_32(data, &mut pos)?;

        let has_rck = read_u8(data, &mut pos)?;
        let receiving_chain_key = if has_rck == 1 {
            Some(read_32(data, &mut pos)?)
        } else {
            None
        };

        let priv_bytes = read_32(data, &mut pos)?;
        let sending_ratchet_private = StaticSecret::from(priv_bytes);
        let pub_bytes = read_32(data, &mut pos)?;
        let sending_ratchet_public = PublicKey::from(pub_bytes);

        let has_rrk = read_u8(data, &mut pos)?;
        let receiving_ratchet_key = if has_rrk == 1 {
            Some(PublicKey::from(read_32(data, &mut pos)?))
        } else {
            None
        };

        let send_counter = read_u32(data, &mut pos)?;
        let recv_counter = read_u32(data, &mut pos)?;
        let prev_send_counter = read_u32(data, &mut pos)?;

        let num_skipped = read_u32(data, &mut pos)?;
        if num_skipped > MAX_SKIP {
            return Err(err("too many skipped keys"));
        }

        let mut skipped_keys = HashMap::with_capacity(num_skipped as usize);
        for _ in 0..num_skipped {
            let rk = read_32(data, &mut pos)?;
            let msg_num = read_u32(data, &mut pos)?;
            let key = read_32(data, &mut pos)?;
            skipped_keys.insert((rk, msg_num), key);
        }

        Ok(Self {
            root_key,
            sending_chain_key,
            receiving_chain_key,
            sending_ratchet_private,
            sending_ratchet_public,
            receiving_ratchet_key,
            send_counter,
            recv_counter,
            prev_send_counter,
            skipped_keys,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: set up Alice and Bob ratchet states from a shared secret.
    fn setup_ratchet_pair() -> (RatchetState, RatchetState) {
        let shared_secret = [42u8; 32];

        // Bob's initial ratchet key (his signed prekey in real X3DH flow)
        let bob_ratchet_private = StaticSecret::random_from_rng(OsRng);
        let bob_ratchet_public = PublicKey::from(&bob_ratchet_private);

        let alice = RatchetState::init_alice(&shared_secret, &bob_ratchet_public).unwrap();
        let bob = RatchetState::init_bob(&shared_secret, bob_ratchet_private).unwrap();

        (alice, bob)
    }

    #[test]
    fn test_encrypt_decrypt_single_message() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        let plaintext = b"Hello Bob!";
        let (ciphertext, header) = alice.encrypt(plaintext).unwrap();
        let decrypted = bob.decrypt(&header, &ciphertext).unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_decrypt_multiple_messages_one_direction() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        for i in 0..10 {
            let msg = format!("Message {i}");
            let (ct, hdr) = alice.encrypt(msg.as_bytes()).unwrap();
            let pt = bob.decrypt(&hdr, &ct).unwrap();
            assert_eq!(pt, msg.as_bytes());
        }
    }

    #[test]
    fn test_encrypt_decrypt_ping_pong() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        // Alice -> Bob
        let (ct, hdr) = alice.encrypt(b"Hi Bob").unwrap();
        let pt = bob.decrypt(&hdr, &ct).unwrap();
        assert_eq!(pt, b"Hi Bob");

        // Bob -> Alice
        let (ct, hdr) = bob.encrypt(b"Hi Alice").unwrap();
        let pt = alice.decrypt(&hdr, &ct).unwrap();
        assert_eq!(pt, b"Hi Alice");

        // Alice -> Bob again
        let (ct, hdr) = alice.encrypt(b"How are you?").unwrap();
        let pt = bob.decrypt(&hdr, &ct).unwrap();
        assert_eq!(pt, b"How are you?");

        // Bob -> Alice again
        let (ct, hdr) = bob.encrypt(b"Good, you?").unwrap();
        let pt = alice.decrypt(&hdr, &ct).unwrap();
        assert_eq!(pt, b"Good, you?");
    }

    #[test]
    fn test_out_of_order_delivery() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        // Alice sends 3 messages
        let (ct0, hdr0) = alice.encrypt(b"msg 0").unwrap();
        let (ct1, hdr1) = alice.encrypt(b"msg 1").unwrap();
        let (ct2, hdr2) = alice.encrypt(b"msg 2").unwrap();

        // Bob receives them out of order: 2, 0, 1
        let pt2 = bob.decrypt(&hdr2, &ct2).unwrap();
        assert_eq!(pt2, b"msg 2");

        let pt0 = bob.decrypt(&hdr0, &ct0).unwrap();
        assert_eq!(pt0, b"msg 0");

        let pt1 = bob.decrypt(&hdr1, &ct1).unwrap();
        assert_eq!(pt1, b"msg 1");
    }

    #[test]
    fn test_forward_secrecy() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        // Alice sends several messages, advancing the sending chain
        let (ct0, hdr0) = alice.encrypt(b"msg 0").unwrap();
        let (ct1, hdr1) = alice.encrypt(b"msg 1").unwrap();
        let (ct2, hdr2) = alice.encrypt(b"msg 2").unwrap();

        // Bob decrypts all of them, consuming the chain keys
        let _ = bob.decrypt(&hdr0, &ct0).unwrap();
        let _ = bob.decrypt(&hdr1, &ct1).unwrap();
        let _ = bob.decrypt(&hdr2, &ct2).unwrap();

        // Forward secrecy property: the message keys for msg 0 and msg 1
        // have been derived and discarded. The chain key has advanced past them.
        // An attacker who captures Bob's current state AFTER decryption cannot
        // re-derive the old message keys because KDF-CK is one-way.
        //
        // We demonstrate this by verifying that the old ciphertexts cannot
        // be decrypted again (the skipped_keys map does not contain them
        // since they were consumed in order).
        let result = bob.decrypt(&hdr0, &ct0);
        assert!(
            result.is_err(),
            "Old message should not be re-decryptable (keys consumed)"
        );

        // Additionally verify that different sessions with different secrets
        // cannot cross-decrypt.
        let (mut eve, _) = setup_ratchet_pair();
        let result = eve.decrypt(&hdr2, &ct2);
        assert!(
            result.is_err(),
            "Different session should not decrypt the message"
        );
    }

    #[test]
    fn test_wrong_key_cannot_decrypt() {
        let (mut alice, _bob) = setup_ratchet_pair();
        let (mut eve, _) = setup_ratchet_pair();

        let (ct, hdr) = alice.encrypt(b"secret").unwrap();

        // Eve (different shared secret) cannot decrypt Alice's message
        let result = eve.decrypt(&hdr, &ct);
        assert!(result.is_err());
    }

    #[test]
    fn test_serialize_deserialize_roundtrip() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        // Exchange some messages
        let (ct, hdr) = alice.encrypt(b"before serialize").unwrap();
        let _ = bob.decrypt(&hdr, &ct).unwrap();

        // Serialize and restore Alice
        let alice_bytes = alice.serialize();
        let mut alice2 = RatchetState::deserialize(&alice_bytes).unwrap();

        // Continue the conversation from restored state
        let (ct2, hdr2) = alice2.encrypt(b"after serialize").unwrap();
        let pt2 = bob.decrypt(&hdr2, &ct2).unwrap();
        assert_eq!(pt2, b"after serialize");
    }

    #[test]
    fn test_message_header_serialize_roundtrip() {
        let hdr = MessageHeader {
            ratchet_public_key: [0xAB; 32],
            prev_chain_length: 42,
            message_number: 7,
        };

        let data = hdr.serialize();
        assert_eq!(data.len(), 40);

        let hdr2 = MessageHeader::deserialize(&data).unwrap();
        assert_eq!(hdr, hdr2);
    }

    #[test]
    fn test_empty_plaintext() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        let (ct, hdr) = alice.encrypt(b"").unwrap();
        let pt = bob.decrypt(&hdr, &ct).unwrap();
        assert!(pt.is_empty());
    }

    #[test]
    fn test_large_message() {
        let (mut alice, mut bob) = setup_ratchet_pair();

        let big_msg = vec![0xCDu8; 64 * 1024]; // 64 KB
        let (ct, hdr) = alice.encrypt(&big_msg).unwrap();
        let pt = bob.decrypt(&hdr, &ct).unwrap();
        assert_eq!(pt, big_msg);
    }
}
