//! Integration tests for WS `send_message` content validation (#832, gap 2).
//!
//! `validate_message_length` (apps/server/src/ws/message_service.rs:66)
//! rejects empty/whitespace-only content and content over
//! `MAX_MESSAGE_LENGTH` (10,000 chars). The check ships an `error`
//! frame back to the sender and persists nothing.
//!
//! Covered:
//!   * empty `content` rejected before persistence
//!   * whitespace-only `content` rejected before persistence
//!   * content of `MAX_MESSAGE_LENGTH + 1` rejected with a "too long"
//!     error
//!
//! We use a plaintext group so the validator runs without the
//! ciphertext-shape gate getting in the way -- the gate only triggers
//! on encrypted conversations (#591).

mod common;

use futures_util::SinkExt;
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_ws(base: &str, ticket: &str) -> WsStream {
    let ws_base = base.replace("http://", "ws://");
    let (ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");
    ws
}

async fn fetch_history(client: &Client, base: &str, token: &str, conv: &str) -> Vec<Value> {
    let resp = client
        .get(format!("{base}/api/messages/{conv}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    resp.json::<Vec<Value>>().await.unwrap()
}

async fn send_and_expect_error(ws: &mut WsStream, frame: Value, error_contains: &str) {
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send failed");
    let evt = common::recv_until_event(ws, &["error", "message_sent"]).await;
    assert_eq!(evt["type"], "error", "expected error frame, got: {evt}");
    let msg = evt["message"]
        .as_str()
        .expect("error frame missing message");
    assert!(
        msg.to_lowercase().contains(&error_contains.to_lowercase()),
        "error message {msg:?} did not contain {error_contains:?}"
    );
}

#[tokio::test]
async fn empty_content_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "wsce_alice_empty").await;
    let group = common::create_group(&client, &base, &alice_token, "EmptyContent").await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": "",
    });
    send_and_expect_error(&mut alice_ws, frame, "empty").await;

    // Nothing should land in history.
    let history = fetch_history(&client, &base, &alice_token, &group).await;
    assert!(
        history.is_empty(),
        "rejected message must not be persisted, history: {history:?}"
    );

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn whitespace_only_content_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "wsce_alice_ws").await;
    let group = common::create_group(&client, &base, &alice_token, "WhitespaceContent").await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // Spaces, tabs, newlines should all trim to nothing.
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": "   \t\n  ",
    });
    send_and_expect_error(&mut alice_ws, frame, "empty").await;

    let history = fetch_history(&client, &base, &alice_token, &group).await;
    assert!(
        history.is_empty(),
        "whitespace-only message must not be persisted, history: {history:?}"
    );

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn content_over_max_length_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "wsce_alice_long").await;
    let group = common::create_group(&client, &base, &alice_token, "LongContent").await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // MAX_MESSAGE_LENGTH is 10_000 bytes; one byte over must reject.
    let too_long = "a".repeat(10_001);
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": too_long,
    });
    send_and_expect_error(&mut alice_ws, frame, "too long").await;

    let history = fetch_history(&client, &base, &alice_token, &group).await;
    assert!(
        history.is_empty(),
        "over-length message must not be persisted, history len: {}",
        history.len()
    );

    let _ = alice_ws.close(None).await;
}
