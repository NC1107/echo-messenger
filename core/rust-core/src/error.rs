//! Unified error types for the Echo core library.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("Network error: {0}")]
    Network(String),

    #[error("Storage error: {0}")]
    Storage(String),

    #[error("Crypto error: {0}")]
    Crypto(String),

    #[error("Auth error: {0}")]
    Auth(String),

    #[error("Invalid input: {0}")]
    InvalidInput(String),
}
