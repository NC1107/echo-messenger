//! Rate-limited WebSocket receive loop.
//!
//! Uses a token bucket algorithm: 30 messages per 10-second window
//! (refill rate = 3 tokens/sec, burst cap = 30). A byte-rate bucket caps
//! throughput at 100 KB/s to prevent bandwidth abuse. After 3 consecutive
//! rate-limit violations the connection is closed.

use axum::extract::ws::{Message as WsMessage, WebSocket};
use futures_util::StreamExt;
use tokio::time::Instant;
use uuid::Uuid;

use crate::routes::AppState;
use crate::ws::error::send_error;
use crate::ws::events::dispatch::handle_text_message;

/// Tokens added per second (30 messages / 10 seconds).
const REFILL_RATE: f64 = 3.0;
/// Maximum tokens the bucket can hold (== window size).
const BUCKET_CAPACITY: f64 = 30.0;
/// Maximum payload size for a single message (64 KB).
const MAX_MESSAGE_BYTES: usize = 64 * 1024;
/// Byte-rate bucket capacity (100 KB).
const BYTE_BUCKET_CAPACITY: f64 = 100.0 * 1024.0;
/// Byte-rate refill (100 KB/s).
const BYTE_REFILL_RATE: f64 = 100.0 * 1024.0;
/// Consecutive violations before forced disconnect.
const MAX_CONSECUTIVE_VIOLATIONS: u32 = 3;

/// Outcome of a single guard check — tells the loop whether to break,
/// continue to the next frame, or proceed with message dispatch.
enum GuardOutcome {
    Disconnect,
    Drop,
    Allow,
}

/// Mutable token-bucket state threaded through each loop iteration.
struct BucketState {
    tokens: f64,
    byte_tokens: f64,
    last_refill: Instant,
    consecutive_violations: u32,
}

impl BucketState {
    fn new() -> Self {
        Self {
            tokens: BUCKET_CAPACITY,
            byte_tokens: BYTE_BUCKET_CAPACITY,
            last_refill: Instant::now(),
            consecutive_violations: 0,
        }
    }

    /// Refill both buckets based on elapsed wall-clock time.
    fn refill(&mut self) {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_refill).as_secs_f64();
        self.tokens = (self.tokens + elapsed * REFILL_RATE).min(BUCKET_CAPACITY);
        self.byte_tokens =
            (self.byte_tokens + elapsed * BYTE_REFILL_RATE).min(BYTE_BUCKET_CAPACITY);
        self.last_refill = now;
    }
}

/// Return the byte cost of a non-text frame (Binary / Ping / Pong → payload
/// length; all others → 0 so they pass through freely).
fn non_text_byte_cost(msg: &WsMessage) -> f64 {
    match msg {
        WsMessage::Binary(b) => b.len() as f64,
        WsMessage::Ping(b) | WsMessage::Pong(b) => b.len() as f64,
        _ => 0.0,
    }
}

/// Check whether a text message exceeds the hard per-message size cap.
/// Returns `GuardOutcome::Allow` when the size is within limits.
fn check_message_size(
    state: &AppState,
    user_id: Uuid,
    username: &str,
    msg_len: usize,
    bucket: &mut BucketState,
) -> GuardOutcome {
    if msg_len <= MAX_MESSAGE_BYTES {
        return GuardOutcome::Allow;
    }
    tracing::warn!(
        user_id = %user_id,
        username = %username,
        bytes = msg_len,
        "WebSocket message exceeds size limit, dropping"
    );
    send_error(state, user_id, "Message too large (max 64 KB)");
    if record_violation(
        state,
        user_id,
        &mut bucket.consecutive_violations,
        MAX_CONSECUTIVE_VIOLATIONS,
    ) {
        GuardOutcome::Disconnect
    } else {
        GuardOutcome::Drop
    }
}

/// Check whether the message-rate token bucket has capacity for one message.
fn check_message_rate(
    state: &AppState,
    user_id: Uuid,
    username: &str,
    bucket: &mut BucketState,
) -> GuardOutcome {
    if bucket.tokens >= 1.0 {
        return GuardOutcome::Allow;
    }
    tracing::warn!(
        user_id = %user_id,
        username = %username,
        "WebSocket rate limit exceeded, dropping message"
    );
    send_error(state, user_id, "Rate limit exceeded, please slow down");
    if record_violation(
        state,
        user_id,
        &mut bucket.consecutive_violations,
        MAX_CONSECUTIVE_VIOLATIONS,
    ) {
        GuardOutcome::Disconnect
    } else {
        GuardOutcome::Drop
    }
}

/// Check whether the byte-rate token bucket has capacity for `cost` bytes.
fn check_byte_rate(
    state: &AppState,
    user_id: Uuid,
    username: &str,
    cost: f64,
    bucket: &mut BucketState,
) -> GuardOutcome {
    if bucket.byte_tokens >= cost {
        return GuardOutcome::Allow;
    }
    tracing::warn!(
        user_id = %user_id,
        username = %username,
        "WebSocket byte-rate limit exceeded, dropping message"
    );
    send_error(state, user_id, "Byte-rate limit exceeded, please slow down");
    if record_violation(
        state,
        user_id,
        &mut bucket.consecutive_violations,
        MAX_CONSECUTIVE_VIOLATIONS,
    ) {
        GuardOutcome::Disconnect
    } else {
        GuardOutcome::Drop
    }
}

// ---------------------------------------------------------------------------
// Per-frame handlers
// ---------------------------------------------------------------------------

/// Process a text frame through all three guards, then dispatch it.
/// Returns `true` when the receive loop should break.
async fn handle_text_frame(
    text: &str,
    user_id: Uuid,
    device_id: i32,
    username: &str,
    state: &AppState,
    bucket: &mut BucketState,
) -> bool {
    let msg_len = text.len();
    let cost = msg_len as f64;

    // Guard 1: hard size cap.
    match check_message_size(state, user_id, username, msg_len, bucket) {
        GuardOutcome::Disconnect => return true,
        GuardOutcome::Drop => return false,
        GuardOutcome::Allow => {}
    }

    // Guard 2: message-rate bucket.
    match check_message_rate(state, user_id, username, bucket) {
        GuardOutcome::Disconnect => return true,
        GuardOutcome::Drop => return false,
        GuardOutcome::Allow => {}
    }

    // Guard 3: byte-rate bucket.
    match check_byte_rate(state, user_id, username, cost, bucket) {
        GuardOutcome::Disconnect => return true,
        GuardOutcome::Drop => return false,
        GuardOutcome::Allow => {}
    }

    bucket.tokens -= 1.0;
    bucket.byte_tokens -= cost;
    bucket.consecutive_violations = 0;
    handle_text_message(text, user_id, device_id, username, state).await;
    false
}

/// Process a non-text, non-close frame: count both message-count AND bytes
/// so zero-byte ping/pong floods can't bypass the per-frame cap.
/// Returns `true` when the receive loop should break.
fn handle_other_frame(
    msg: &WsMessage,
    state: &AppState,
    user_id: Uuid,
    bucket: &mut BucketState,
) -> bool {
    // TD-36: each frame costs a message token — byte bucket alone misses
    // zero-byte ping floods.
    if bucket.tokens < 1.0 {
        return record_violation(
            state,
            user_id,
            &mut bucket.consecutive_violations,
            MAX_CONSECUTIVE_VIOLATIONS,
        );
    }

    let cost = non_text_byte_cost(msg);
    if cost > bucket.byte_tokens {
        return record_violation(
            state,
            user_id,
            &mut bucket.consecutive_violations,
            MAX_CONSECUTIVE_VIOLATIONS,
        );
    }

    bucket.tokens -= 1.0;
    bucket.byte_tokens -= cost;
    bucket.consecutive_violations = 0;
    false
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub(super) async fn run_receive_loop(
    receiver: &mut futures_util::stream::SplitStream<WebSocket>,
    user_id: Uuid,
    device_id: i32,
    username: &str,
    state: &AppState,
) {
    let mut bucket = BucketState::new();

    while let Some(Ok(msg)) = receiver.next().await {
        bucket.refill();

        let should_break = match msg {
            WsMessage::Text(ref text) => {
                handle_text_frame(text, user_id, device_id, username, state, &mut bucket).await
            }
            WsMessage::Close(_) => break,
            ref other => handle_other_frame(other, state, user_id, &mut bucket),
        };

        if should_break {
            break;
        }
    }
}

/// Record a rate-limit violation and send a disconnect notice when the
/// threshold is reached.  Returns `true` when the caller should break the
/// receive loop, `false` when it should only `continue`.
fn record_violation(
    state: &AppState,
    user_id: Uuid,
    consecutive_violations: &mut u32,
    max_violations: u32,
) -> bool {
    *consecutive_violations += 1;
    if *consecutive_violations >= max_violations {
        tracing::warn!(
            user_id = %user_id,
            "Disconnecting after {} consecutive violations",
            consecutive_violations
        );
        send_error(state, user_id, "Too many violations, disconnecting");
        return true;
    }
    false
}
