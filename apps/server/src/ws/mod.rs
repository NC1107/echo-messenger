pub mod broadcast;
pub(crate) mod error;
pub(crate) mod events;
pub mod handler;
pub mod hub;
pub(crate) mod message_service;
pub(crate) mod protocol;
pub(crate) mod rate_limit;
pub mod rotation;
pub mod typing_service;

/// Re-export of the per-lounge canvas authority store so binary crates
/// (main.rs) and integration tests can construct it without depending on
/// the otherwise-internal `events` module.
pub use events::canvas_authority::CanvasAuthority;
