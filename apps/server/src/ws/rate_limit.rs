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

pub(super) async fn run_receive_loop(
    receiver: &mut futures_util::stream::SplitStream<WebSocket>,
    user_id: Uuid,
    device_id: i32,
    username: &str,
    state: &AppState,
) {
    let mut tokens: f64 = BUCKET_CAPACITY;
    let mut byte_tokens: f64 = BYTE_BUCKET_CAPACITY;
    let mut last_refill = Instant::now();
    let mut consecutive_violations: u32 = 0;

    while let Some(Ok(msg)) = receiver.next().await {
        // Refill tokens based on elapsed time.
        let now = Instant::now();
        let elapsed = now.duration_since(last_refill).as_secs_f64();
        tokens = (tokens + elapsed * REFILL_RATE).min(BUCKET_CAPACITY);
        byte_tokens = (byte_tokens + elapsed * BYTE_REFILL_RATE).min(BYTE_BUCKET_CAPACITY);
        last_refill = now;

        match msg {
            WsMessage::Text(text) => {
                let msg_len = text.len();

                // Reject oversized messages immediately.
                if msg_len > MAX_MESSAGE_BYTES {
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
                        &mut consecutive_violations,
                        MAX_CONSECUTIVE_VIOLATIONS,
                    ) {
                        break;
                    }
                    continue;
                }

                // Check message-rate bucket.
                if tokens < 1.0 {
                    tracing::warn!(
                        user_id = %user_id,
                        username = %username,
                        "WebSocket rate limit exceeded, dropping message"
                    );
                    send_error(state, user_id, "Rate limit exceeded, please slow down");
                    if record_violation(
                        state,
                        user_id,
                        &mut consecutive_violations,
                        MAX_CONSECUTIVE_VIOLATIONS,
                    ) {
                        break;
                    }
                    continue;
                }

                // Check byte-rate bucket.
                let cost = msg_len as f64;
                if byte_tokens < cost {
                    tracing::warn!(
                        user_id = %user_id,
                        username = %username,
                        "WebSocket byte-rate limit exceeded, dropping message"
                    );
                    send_error(state, user_id, "Byte-rate limit exceeded, please slow down");
                    if record_violation(
                        state,
                        user_id,
                        &mut consecutive_violations,
                        MAX_CONSECUTIVE_VIOLATIONS,
                    ) {
                        break;
                    }
                    continue;
                }

                tokens -= 1.0;
                byte_tokens -= cost;
                consecutive_violations = 0;
                handle_text_message(&text, user_id, device_id, username, state).await;
            }
            WsMessage::Close(_) => break,
            // Binary/Ping/Pong frames: count bytes toward the rate limit to
            // prevent abuse via non-text frames.
            other => {
                let cost = match &other {
                    WsMessage::Binary(b) => b.len() as f64,
                    WsMessage::Ping(b) | WsMessage::Pong(b) => b.len() as f64,
                    _ => 0.0,
                };
                if cost > 0.0 {
                    if byte_tokens < cost {
                        if record_violation(
                            state,
                            user_id,
                            &mut consecutive_violations,
                            MAX_CONSECUTIVE_VIOLATIONS,
                        ) {
                            break;
                        }
                        continue;
                    }
                    byte_tokens -= cost;
                    consecutive_violations = 0;
                }
            }
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
