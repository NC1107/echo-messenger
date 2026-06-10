//! Per-event-type handlers dispatched from the main WebSocket receive loop.

pub(super) mod broadcast;
pub(super) mod canvas;
pub(crate) mod canvas_authority;
pub(super) mod canvas_validation;
pub(super) mod dispatch;
pub(crate) mod voice;
