//! Public API surface for the Echo core library.
//! This file defines the FFI boundary between Rust and Dart.

use crate::error::CoreError;

/// Main entry point for the Echo core library.
pub struct EchoCore {
    // Will hold storage, network, crypto managers
}

impl EchoCore {
    /// Initialize the core with a database path.
    pub async fn initialize(db_path: String) -> Result<Self, CoreError> {
        tracing::info!("Initializing Echo core with db: {}", db_path);
        Ok(Self {})
    }

    /// Register a new account on the server.
    pub async fn register(
        &self,
        _server_url: &str,
        username: &str,
        _password: &str,
    ) -> Result<String, CoreError> {
        tracing::info!("Registering user: {}", username);
        todo!("Implement registration")
    }

    /// Login to an existing account.
    pub async fn login(
        &self,
        _server_url: &str,
        username: &str,
        _password: &str,
    ) -> Result<String, CoreError> {
        tracing::info!("Logging in user: {}", username);
        todo!("Implement login")
    }
}
