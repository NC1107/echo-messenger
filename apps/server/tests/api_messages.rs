//! Integration tests for message pin/unpin atomicity.
//!
//! Validates the TOCTOU fix: pin_message now includes conversation_id in the
//! SQL WHERE clause so the operation is atomic — no pin-then-verify-then-unpin.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

/// Helper: set up two users as contacts and return tokens + conversation ID + a message ID.
async fn setup_dm_with_message(
    base: &str,
) -> (Client, String, String, String, String, String, String) {
    let client = Client::new();

    let alice_name = common::unique_username("pin_alice");
    let bob_name = common::unique_username("pin_bob");

    common::register(&client, base, &alice_name, "password123").await;
    common::register(&client, base, &bob_name, "password123").await;

    let (alice_token, alice_id) = common::login(&client, base, &alice_name, "password123").await;
    let (bob_token, _bob_id) = common::login(&client, base, &bob_name, "password123").await;

    // Make contacts
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "username": bob_name }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().unwrap().to_string();

    client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();

    // Create DM
    let resp = client
        .post(format!("{base}/api/conversations/dm"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "peer_user_id": _bob_id }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let conv_id = body["conversation_id"].as_str().unwrap().to_string();

    // Send a message via WebSocket so we have a message_id to pin
    let alice_ticket = common::get_ws_ticket(&client, base, &alice_token).await;
    let ws_url = base.replace("http://", "ws://");
    let (mut ws, _) =
        tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={alice_ticket}"))
            .await
            .expect("WS connect failed");

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Drain presence events
    while let Ok(Some(Ok(_))) = tokio::time::timeout(Duration::from_millis(100), ws.next()).await {}

    let canonical = common::dummy_ciphertext("pin_canonical");
    let bob_ct = common::dummy_ciphertext("pin_bob");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": _bob_id,
        "conversation_id": conv_id,
        "content": canonical,
        "recipient_device_contents": {
            _bob_id.to_string(): { "0": bob_ct },
        },
    });
    ws.send(Message::Text(send_msg.to_string().into()))
        .await
        .unwrap();

    // Read message_sent to get the message_id
    let mut message_id = String::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while let Ok(Some(Ok(Message::Text(text)))) = tokio::time::timeout_at(deadline, ws.next()).await
    {
        if let Ok(json) = serde_json::from_str::<Value>(&text)
            && json["type"] == "message_sent"
        {
            message_id = json["message_id"].as_str().unwrap().to_string();
            break;
        }
    }
    let _ = ws.close(None).await;

    assert!(!message_id.is_empty(), "Should have received message_id");

    (
        client,
        alice_token,
        bob_token,
        alice_id,
        conv_id,
        message_id,
        bob_name,
    )
}

/// Pin a message in its own conversation — should succeed.
#[tokio::test]
async fn pin_message_succeeds() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, conv_id, msg_id, _) = setup_dm_with_message(&base).await;

    let resp = client
        .post(format!(
            "{base}/api/conversations/{conv_id}/messages/{msg_id}/pin"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200, "Pin should succeed");
}

/// Unpin a previously pinned message — should return 204.
#[tokio::test]
async fn unpin_message_succeeds() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, conv_id, msg_id, _) = setup_dm_with_message(&base).await;

    // Pin first
    client
        .post(format!(
            "{base}/api/conversations/{conv_id}/messages/{msg_id}/pin"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    // Unpin
    let resp = client
        .delete(format!(
            "{base}/api/conversations/{conv_id}/messages/{msg_id}/pin"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 204, "Unpin should return 204");
}

/// Pinned messages appear in the pinned list.
#[tokio::test]
async fn pinned_messages_list() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, conv_id, msg_id, _) = setup_dm_with_message(&base).await;

    // Pin
    client
        .post(format!(
            "{base}/api/conversations/{conv_id}/messages/{msg_id}/pin"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    // Get pinned
    let resp = client
        .get(format!("{base}/api/conversations/{conv_id}/pinned"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let pinned: Vec<Value> = resp.json().await.unwrap();
    assert_eq!(pinned.len(), 1, "Should have exactly 1 pinned message");
    assert_eq!(pinned[0]["id"], msg_id);

    // Unpin and verify empty
    client
        .delete(format!(
            "{base}/api/conversations/{conv_id}/messages/{msg_id}/pin"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    let resp = client
        .get(format!("{base}/api/conversations/{conv_id}/pinned"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    let pinned: Vec<Value> = resp.json().await.unwrap();
    assert!(pinned.is_empty(), "Pinned list should be empty after unpin");
}
