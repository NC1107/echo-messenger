//! Message encryption and decryption using AES-256-GCM.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use rand_core::RngCore;

use crate::error::CoreError;

/// Encrypt plaintext with AES-256-GCM.
///
/// Returns `nonce (12 bytes) || ciphertext || tag (16 bytes)`.
pub fn encrypt(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, CoreError> {
    let cipher_key = Key::<Aes256Gcm>::from_slice(key);
    let cipher = Aes256Gcm::new(cipher_key);

    let mut nonce_bytes = [0u8; 12];
    rand_core::OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| CoreError::Crypto(format!("Encryption failed: {e}")))?;

    // Prepend nonce to ciphertext
    let mut result = Vec::with_capacity(12 + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

/// Decrypt ciphertext produced by [`encrypt`].
///
/// Expects input format: `nonce (12 bytes) || ciphertext || tag (16 bytes)`.
pub fn decrypt(key: &[u8; 32], data: &[u8]) -> Result<Vec<u8>, CoreError> {
    if data.len() < 12 + 16 {
        return Err(CoreError::Crypto(
            "Ciphertext too short (must be at least 28 bytes)".into(),
        ));
    }

    let (nonce_bytes, ciphertext) = data.split_at(12);
    let nonce = Nonce::from_slice(nonce_bytes);

    let cipher_key = Key::<Aes256Gcm>::from_slice(key);
    let cipher = Aes256Gcm::new(cipher_key);

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| CoreError::Crypto(format!("Decryption failed: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = [42u8; 32];
        let plaintext = b"Hello, encrypted world!";

        let encrypted = encrypt(&key, plaintext).unwrap();
        // Encrypted output should be nonce (12) + plaintext (23) + tag (16) = 51 bytes
        assert_eq!(encrypted.len(), 12 + 23 + 16);

        let decrypted = decrypt(&key, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_decrypt_with_wrong_key_fails() {
        let key = [42u8; 32];
        let wrong_key = [99u8; 32];
        let plaintext = b"Secret message";

        let encrypted = encrypt(&key, plaintext).unwrap();
        let result = decrypt(&wrong_key, &encrypted);
        assert!(result.is_err());
    }

    #[test]
    fn test_decrypt_short_ciphertext_fails() {
        let key = [42u8; 32];
        let result = decrypt(&key, &[0u8; 10]);
        assert!(result.is_err());
    }

    #[test]
    fn test_decrypt_tampered_ciphertext_fails() {
        let key = [42u8; 32];
        let plaintext = b"Hello";

        let mut encrypted = encrypt(&key, plaintext).unwrap();
        // Flip a byte in the ciphertext area
        let last = encrypted.len() - 1;
        encrypted[last] ^= 0xFF;

        let result = decrypt(&key, &encrypted);
        assert!(result.is_err());
    }

    #[test]
    fn test_empty_plaintext() {
        let key = [42u8; 32];
        let plaintext = b"";

        let encrypted = encrypt(&key, plaintext).unwrap();
        assert_eq!(encrypted.len(), 12 + 16); // nonce + tag only

        let decrypted = decrypt(&key, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_large_message() {
        let key = [42u8; 32];
        let plaintext = vec![0xABu8; 10 * 1024]; // 10 KB

        let encrypted = encrypt(&key, &plaintext).unwrap();
        assert_eq!(encrypted.len(), 12 + plaintext.len() + 16);

        let decrypted = decrypt(&key, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }
}
