//! Cryptographic operations for end-to-end encryption.
//!
//! This module contains:
//! - Key generation and management (Ed25519 + X25519)
//! - Session establishment (X3DH key agreement)
//! - Message encryption/decryption (AES-256-GCM)
//! - Signal Protocol store implementations backed by SQLCipher (future)

pub mod encrypt;
pub mod keys;
pub mod session;
