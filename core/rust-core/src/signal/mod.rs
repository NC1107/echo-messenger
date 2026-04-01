//! Signal Protocol implementation: X3DH key agreement + Double Ratchet.
//!
//! This module provides end-to-end encryption using the Signal Protocol:
//! - **keys**: Key types and generation (identity, signed prekeys, ephemeral)
//! - **x3dh**: Extended Triple Diffie-Hellman for session establishment
//! - **ratchet**: Double Ratchet for per-message forward secrecy
//! - **session**: High-level session management API

pub mod keys;
pub mod ratchet;
pub mod session;
pub mod x3dh;
