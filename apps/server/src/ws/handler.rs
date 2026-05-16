//! WebSocket session lifecycle.
//!
//! `handle_socket` runs for the lifetime of a single connected device:
//! register in the hub, broadcast presence, spawn the heartbeat task, run the
//! send/receive loops, then unwind (unregister + voice-cleanup + offline
//! presence) when either side closes.
//!
//! The wire-format types, error helper, rate limiter, and per-event handlers
//! live in sibling submodules (`protocol`, `error`, `rate_limit`, `events`).
//! This file re-exports the public surface (`ServerMessage`, `send_error`) so
//! existing callers (`routes::ws`, `routes::keys`, `message_service`, etc.)
//! continue to import them from `ws::handler` unchanged.

use axum::extract::ws::{Message as WsMessage, WebSocket};
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::ws::events::voice::cleanup_user_voice_sessions;
use crate::ws::message_service;
use crate::ws::rate_limit::run_receive_loop;
use crate::ws::typing_service;

// Re-exports — these names live in submodules now, but external callers still
// reach them through `ws::handler::{ServerMessage, send_error}`.
pub use crate::ws::error::send_error;
pub use crate::ws::protocol::ServerMessage;

/// Application-level heartbeat payload (#829).
///
/// Browser WebSocket APIs swallow protocol-level Ping/Pong before they reach
/// JavaScript, so the JSON heartbeat is the only signal a browser client can
/// observe to confirm the socket is still alive. Hoisted to a `&'static str`
/// so the 30-second tick doesn't allocate a fresh `String` per heartbeat.
const HEARTBEAT_PAYLOAD: &str = r#"{"type":"heartbeat"}"#;

pub async fn handle_socket(
    socket: WebSocket,
    user_id: Uuid,
    device_id: i32,
    username: String,
    state: Arc<AppState>,
) {
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::channel::<WsMessage>(256);

    // Register in hub (multi-device: keyed by user_id + device_id)
    state.hub.register(user_id, device_id, tx);

    // Broadcast online presence to contacts
    typing_service::broadcast_presence(&state, user_id, &username, "online").await;

    // Send a presence_list snapshot to the newly-connected user so it can
    // replace any stale online-set from before the reconnect (#436).
    typing_service::send_presence_snapshot(&state, user_id).await;

    // Forward hub -> sink. Both halves are select!-linked below so neither
    // outlives the other; rx returned for post-shutdown drain.
    let send_fut = async move {
        while let Some(msg) = rx.recv().await {
            if sender.send(msg).await.is_err() {
                break;
            }
        }
        (sender, rx)
    };
    tokio::pin!(send_fut);

    // Task: send heartbeat every 30 seconds to keep the connection alive
    // through reverse-proxy (Traefik/Cloudflare) idle timeouts.
    //
    // We send BOTH a WebSocket protocol Ping (for proxy keepalive) and an
    // application-level JSON heartbeat. Browser WebSocket APIs handle
    // Ping/Pong transparently without surfacing them to JavaScript, so the
    // client's heartbeat monitor would never see protocol Pings.  The JSON
    // heartbeat triggers the browser's onMessage callback, letting the
    // client know the connection is still alive.
    let ping_hub = state.hub.clone();
    let ping_user_id = user_id;
    let ping_device_id = device_id;
    let ping_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        // The first tick fires immediately; skip it.
        interval.tick().await;
        loop {
            interval.tick().await;
            // Protocol-level Ping (proxy keepalive; invisible to browsers).
            ping_hub.send_to_device(
                &ping_user_id,
                ping_device_id,
                WsMessage::Ping(vec![].into()),
            );
            // Application-level heartbeat (visible to all clients).
            // #829: payload is a module-level `&'static str` to avoid the
            // per-tick `String` allocation.
            if !ping_hub.send_to_device(
                &ping_user_id,
                ping_device_id,
                WsMessage::Text(HEARTBEAT_PAYLOAD.into()),
            ) {
                break;
            }
        }
    });

    // Update device last_seen so the management UI reflects recent activity.
    // Fire-and-forget: the connection must not block on a DB write here.
    {
        let pool = state.pool.clone();
        tokio::spawn(async move {
            if let Err(e) = db::keys::update_last_seen(&pool, user_id, device_id).await {
                tracing::warn!(
                    "update_last_seen failed for user {user_id} device {device_id}: {e}"
                );
            }
        });
    }

    message_service::deliver_undelivered_messages(&state, user_id, device_id).await;

    // Run receive + send concurrently. Whichever finishes first triggers the
    // tear-down; the other half is awaited (or dropped) in the cleanup arm.
    let recv_fut = run_receive_loop(&mut receiver, user_id, device_id, &username, &state);
    tokio::pin!(recv_fut);

    let leftover_rx: Option<mpsc::Receiver<WsMessage>> = tokio::select! {
        _ = &mut recv_fut => {
            // Receive loop ended -- the send half might still have pending
            // frames in `rx`. Unregister so no new ones land, then attempt a
            // brief drain (50ms) to flush what's already buffered.
            state.hub.unregister(user_id, device_id);
            // Pull the sink + rx back out of the send future by polling
            // it once with a tight timeout. If the channel was already
            // closed by `unregister` (which dropped the tx) the future
            // resolves immediately; otherwise the timeout caps it.
            match tokio::time::timeout(Duration::from_millis(50), &mut send_fut).await {
                Ok((_sender, rx)) => Some(rx),
                Err(_) => None,
            }
        }
        (_sender, rx) = &mut send_fut => {
            // Send half ended (peer TCP died, or rx was closed). Stop
            // accepting new inbound frames by unregistering, then let the
            // recv future complete naturally as the underlying socket
            // surfaces the error.
            state.hub.unregister(user_id, device_id);
            // Best-effort: give the recv loop a moment to observe the
            // socket close before we drop it.
            let _ = tokio::time::timeout(Duration::from_millis(50), &mut recv_fut).await;
            Some(rx)
        }
    };
    drop(leftover_rx);
    // #829: abort the heartbeat task on any disconnect path (clean close OR
    // the err arm of the recv loop both flow through this select! cleanup).
    // Without the explicit abort, the 30 s tick keeps firing until
    // `send_to_device` returns false on the dropped queue -- one or two
    // extra ticks past the disconnect under load.
    ping_task.abort();

    cleanup_user_voice_sessions(&state, user_id).await;

    // Broadcast offline presence to contacts
    typing_service::broadcast_presence(&state, user_id, &username, "offline").await;

    tracing::info!("WebSocket disconnected: {} ({})", username, user_id);
}
