//! Per-event-type handlers dispatched from the main WebSocket receive loop.

pub(super) mod broadcast;
pub(super) mod canvas;
pub(super) mod dispatch;
pub(super) mod voice;
