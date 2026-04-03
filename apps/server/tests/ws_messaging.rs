//! Integration test for WebSocket messaging between two users.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

/// Full end-to-end test: register two users, make them contacts, connect via
/// WebSocket, send a message from Alice to Bob, and verify both sides receive
/// the expected server events.
#[tokio::test]
async fn alice_sends_bob_receives() {
    let base = common::spawn_server().await;
    let client = Client::new();

    // -- Register Alice and Bob -----------------------------------------------
    let alice_name = common::unique_username("alice");
    let bob_name = common::unique_username("bob");

    common::register(&client, &base, &alice_name, "password123").await;
    common::register(&client, &base, &bob_name, "password123").await;

    let (alice_token, _alice_id) = common::login(&client, &base, &alice_name, "password123").await;
    let (bob_token, bob_id) = common::login(&client, &base, &bob_name, "password123").await;

    // -- Make them contacts ---------------------------------------------------
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "username": bob_name }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().unwrap();

    let resp = client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // -- Get WS tickets -------------------------------------------------------
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    // -- Connect WebSockets ---------------------------------------------------
    let ws_base = base.replace("http://", "ws://");

    let (mut alice_ws, _) =
        tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={alice_ticket}"))
            .await
            .expect("Alice WS connect failed");

    let (mut bob_ws, _) =
        tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={bob_ticket}"))
            .await
            .expect("Bob WS connect failed");

    // Give the server a moment to register both connections and deliver any
    // presence events before we send a message.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    // Drain any presence/backlog messages from both sockets before the test
    // message so they don't interfere with assertions.
    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // -- Alice sends a message to Bob -----------------------------------------
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": "Hello from integration test!",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // -- Alice should receive `message_sent` ----------------------------------
    let alice_event = read_text_with_timeout(&mut alice_ws).await;
    let alice_msg: Value = serde_json::from_str(&alice_event).expect("Alice JSON parse failed");
    assert_eq!(
        alice_msg["type"], "message_sent",
        "Alice should get message_sent"
    );

    // -- Bob should receive `new_message` -------------------------------------
    let bob_event = read_text_with_timeout(&mut bob_ws).await;
    let bob_msg: Value = serde_json::from_str(&bob_event).expect("Bob JSON parse failed");
    assert_eq!(bob_msg["type"], "new_message", "Bob should get new_message");
    assert_eq!(
        bob_msg["content"], "Hello from integration test!",
        "Message content should match"
    );
    assert_eq!(
        bob_msg["from_username"],
        alice_name.as_str(),
        "from_username should be Alice"
    );

    // Clean up
    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

/// Read a text message from the WebSocket with a 5-second timeout.
/// Panics if no text message arrives in time.
async fn read_text_with_timeout(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> String {
    let timeout = std::time::Duration::from_secs(5);
    loop {
        match tokio::time::timeout(timeout, ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => return text.to_string(),
            Ok(Some(Ok(Message::Ping(_)))) => continue,
            Ok(Some(Ok(Message::Pong(_)))) => continue,
            Ok(Some(Ok(other))) => panic!("Unexpected WS message: {other:?}"),
            Ok(Some(Err(e))) => panic!("WS error: {e}"),
            Ok(None) => panic!("WS stream ended unexpectedly"),
            Err(_) => panic!("Timed out waiting for WS message"),
        }
    }
}

/// Drain any pending messages from the socket (non-blocking).
async fn drain_pending(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) {
    while let Ok(Some(Ok(_))) =
        tokio::time::timeout(std::time::Duration::from_millis(100), ws.next()).await
    {}
}
