//! Integration tests for WebSocket ticket authentication security invariants.
//!
//! Verifies that:
//!   - A raw JWT cannot be used in place of a ticket.
//!   - A bogus / unknown ticket is rejected before the WS upgrade.
//!   - A valid ticket can only be used once (single-use enforcement at HTTP level).
//!   - A missing ticket parameter is rejected.

mod common;

use reqwest::Client;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Attempt a WebSocket upgrade and return whether the connection succeeded.
async fn try_connect_ws(base: &str, query: &str) -> bool {
    let ws_base = base.replace("http://", "ws://");
    tokio_tungstenite::connect_async(format!("{ws_base}/ws?{query}"))
        .await
        .is_ok()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Using a raw JWT access token as the WebSocket `ticket` query parameter
/// must be rejected — JWTs are NOT valid WS tickets.
///
/// Security invariant: the server must never accept a long-lived JWT on the
/// WebSocket URL (browser history / referrer header exposure).
#[tokio::test]
async fn raw_jwt_as_ticket_is_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (jwt, _, _) = common::register_and_login(&client, &base, "wssec_jwt").await;

    // Pass the JWT directly as the ticket value — the server looks it up in
    // ticket_store (which contains only opaque random tokens, never JWTs)
    // and must return 401 before the WS upgrade completes.
    let connected = try_connect_ws(&base, &format!("ticket={jwt}")).await;
    assert!(!connected, "a raw JWT must not be accepted as a WS ticket");
}

/// A completely bogus / random ticket value must be rejected with a
/// connection error (server returns 401 before WS upgrade).
#[tokio::test]
async fn bogus_ticket_is_rejected() {
    let base = common::spawn_server().await;

    let connected = try_connect_ws(&base, "ticket=completely-bogus-value").await;
    assert!(!connected, "a bogus ticket must not be accepted");
}

/// An empty ticket string must be rejected.
#[tokio::test]
async fn empty_ticket_is_rejected() {
    let base = common::spawn_server().await;

    let connected = try_connect_ws(&base, "ticket=").await;
    assert!(!connected, "an empty ticket string must not be accepted");
}

/// A valid ticket can only be used ONCE at the integration level.
///
/// This mirrors the unit test in `routes/ws.rs` but exercises the full
/// HTTP request path through the real Axum router, including the
/// `remove_if` atomic consumption.
#[tokio::test]
async fn ticket_is_single_use_at_integration_level() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "wssec_once").await;

    // Obtain a single ticket.
    let ticket = common::get_ws_ticket(&client, &base, &token).await;

    // First use: connection must succeed and the ticket is consumed.
    let ws_base = base.replace("http://", "ws://");
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
        .await
        .expect("first WS connection should succeed");
    let _ = ws.close(None).await;

    // Second use: the ticket has been consumed; connection must fail.
    let second = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}")).await;
    assert!(
        second.is_err(),
        "replaying the same ticket must be rejected"
    );
}

/// Connecting without any `ticket` query parameter must be rejected.
///
/// Axum's Query extractor returns 422 when a required parameter is missing,
/// which also causes the WS upgrade to fail.
#[tokio::test]
async fn missing_ticket_param_is_rejected() {
    let base = common::spawn_server().await;

    let ws_base = base.replace("http://", "ws://");
    let result = tokio_tungstenite::connect_async(format!("{ws_base}/ws")).await;
    assert!(
        result.is_err(),
        "connecting without a ticket parameter must fail"
    );
}
