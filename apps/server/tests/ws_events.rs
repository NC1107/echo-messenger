//! Integration tests for WebSocket event broadcasting from REST endpoints.
//!
//! Verifies that REST mutations (reaction add/remove, message delete, message
//! edit) trigger the corresponding WebSocket events to connected clients.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_ws(base: &str, ticket: &str) -> WsStream {
    let ws_base = base.replace("http://", "ws://");
    let (ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");
    ws
}

/// Drain pending frames with a short timeout so later assertions start clean.
async fn drain_pending(ws: &mut WsStream) {
    while let Ok(Some(Ok(_))) =
        tokio::time::timeout(std::time::Duration::from_millis(100), ws.next()).await
    {}
}

/// Read text frames, skipping `presence` and `new_message` events.
/// `new_message` arrives asynchronously when the server replays undelivered
/// messages on WS connect; tests that exercise reactions/deletes/edits don't
/// care about it and would otherwise race with `drain_pending`.
async fn read_text_skipping_noise(ws: &mut WsStream) -> String {
    let timeout = std::time::Duration::from_secs(5);
    loop {
        match tokio::time::timeout(timeout, ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                let s = text.to_string();
                if let Ok(v) = serde_json::from_str::<Value>(&s)
                    && matches!(v["type"].as_str(), Some("presence") | Some("new_message"))
                {
                    continue;
                }
                return s;
            }
            Ok(Some(Ok(Message::Ping(_) | Message::Pong(_)))) => continue,
            Ok(Some(Ok(Message::Close(_)))) => panic!("WS closed before expected event"),
            Ok(Some(Ok(other))) => panic!("unexpected WS frame: {other:?}"),
            Ok(Some(Err(e))) => panic!("WS error: {e}"),
            Ok(None) => panic!("WS stream ended unexpectedly"),
            Err(_) => panic!("timed out waiting for WS event"),
        }
    }
}

/// Set up two users as contacts, send one WS message, return useful handles.
///
/// Returns `(client, alice_token, alice_id, bob_token, bob_id, conv_id, message_id)`.
async fn setup_dm_with_message(
    base: &str,
) -> (Client, String, String, String, String, String, String) {
    let client = Client::new();

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, base, "wsev_alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, base, "wsev_bob").await;

    let conv_id =
        common::make_contacts(&client, base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice connects to send a message and obtain a real message_id.
    let alice_ticket = common::get_ws_ticket(&client, base, &alice_token).await;
    let mut alice_ws = connect_ws(base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    // DMs are auto-encrypted, so the ciphertext-shape gate (#591) requires
    // a wire-shaped canonical content and per-recipient device ciphertexts.
    let canonical = common::dummy_ciphertext("wsev_canonical");
    let bob_ct = common::dummy_ciphertext("wsev_bob_d0");
    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "send_message",
                "to_user_id": bob_id,
                "conversation_id": conv_id,
                "content": canonical.clone(),
                "recipient_device_contents": {
                    bob_id.to_string(): { "0": bob_ct },
                    alice_id.to_string(): { "0": canonical },
                },
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("alice send failed");

    let raw = read_text_skipping_noise(&mut alice_ws).await;
    let ack: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(
        ack["type"], "message_sent",
        "setup: expected message_sent ack"
    );
    let message_id = ack["message_id"].as_str().unwrap().to_string();

    let _ = alice_ws.close(None).await;

    (
        client,
        alice_token,
        alice_id,
        bob_token,
        bob_id,
        conv_id,
        message_id,
    )
}

// ---------------------------------------------------------------------------
// Reaction WS broadcast
// ---------------------------------------------------------------------------

/// When Alice adds a reaction via REST, Bob (a connected WS client) should
/// receive a `reaction` event with `action: "add"`.
#[tokio::test]
async fn add_reaction_broadcasts_ws_event_to_peer() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, bob_token, _, _, message_id) = setup_dm_with_message(&base).await;

    // Bob connects via WS to receive the reaction broadcast.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    drain_pending(&mut bob_ws).await;

    // Alice adds a reaction via REST.
    let resp = client
        .post(format!("{base}/api/messages/{message_id}/reactions"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "emoji": "👍" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);

    // Bob should receive the `reaction` WS event.
    let event_text = read_text_skipping_noise(&mut bob_ws).await;
    let event: Value = serde_json::from_str(&event_text).unwrap();
    assert_eq!(
        event["type"], "reaction",
        "Bob should receive a reaction event"
    );
    assert_eq!(event["message_id"], message_id.as_str());
    assert_eq!(event["emoji"], "👍");
    assert_eq!(event["action"], "add");

    let _ = bob_ws.close(None).await;
}

/// When Alice removes a reaction via REST, Bob should receive a `reaction`
/// event with `action: "remove"`.
#[tokio::test]
async fn remove_reaction_broadcasts_ws_event_to_peer() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, bob_token, _, _, message_id) = setup_dm_with_message(&base).await;

    // Alice adds a reaction first (REST, no WS listener needed).
    client
        .post(format!("{base}/api/messages/{message_id}/reactions"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "emoji": "🎉" }))
        .send()
        .await
        .unwrap();

    // Bob connects.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    drain_pending(&mut bob_ws).await;

    // Alice removes the reaction.
    let resp = client
        .delete(format!("{base}/api/messages/{message_id}/reactions/🎉"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Bob should receive a `reaction` removal event.
    let event_text = read_text_skipping_noise(&mut bob_ws).await;
    let event: Value = serde_json::from_str(&event_text).unwrap();
    assert_eq!(event["type"], "reaction");
    assert_eq!(event["message_id"], message_id.as_str());
    assert_eq!(event["emoji"], "🎉");
    assert_eq!(event["action"], "remove");

    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Message delete WS broadcast
// ---------------------------------------------------------------------------

/// When Alice deletes her message via REST, Bob (a connected WS client)
/// should receive a `message_deleted` event.
#[tokio::test]
async fn delete_message_broadcasts_ws_event_to_peer() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, bob_token, _, conv_id, message_id) =
        setup_dm_with_message(&base).await;

    // Bob connects to receive the broadcast.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    drain_pending(&mut bob_ws).await;

    // Alice deletes the message via REST.
    let resp = client
        .delete(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 204);

    // Bob should receive `message_deleted`.
    let event_text = read_text_skipping_noise(&mut bob_ws).await;
    let event: Value = serde_json::from_str(&event_text).unwrap();
    assert_eq!(event["type"], "message_deleted");
    assert_eq!(event["message_id"], message_id.as_str());
    assert_eq!(event["conversation_id"], conv_id.as_str());

    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Message edit WS broadcast
// ---------------------------------------------------------------------------

/// Edits on encrypted DMs are rejected at the REST layer (#582), so no
/// `message_edited` event is broadcast. This test verifies the rejection
/// path: Alice's PUT returns 409 and Bob's WS receives no edit frame.
#[tokio::test]
async fn edit_message_on_encrypted_dm_rejected_no_broadcast() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, bob_token, _, _conv_id, message_id) =
        setup_dm_with_message(&base).await;

    // Bob connects.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    drain_pending(&mut bob_ws).await;

    // Alice attempts to edit on an encrypted DM — rejected with 409.
    let resp = client
        .put(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "content": "edited content" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 409);

    // Bob should NOT receive a `message_edited` event within a short window.
    let saw_edit = tokio::time::timeout(std::time::Duration::from_millis(500), async {
        loop {
            match bob_ws.next().await {
                Some(Ok(Message::Text(text))) => {
                    if let Ok(v) = serde_json::from_str::<Value>(&text)
                        && v["type"] == "message_edited"
                    {
                        return true;
                    }
                }
                Some(Ok(_)) => continue,
                Some(Err(_)) | None => return false,
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(
        !saw_edit,
        "no message_edited should be broadcast for rejected edit"
    );

    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Presence events
// ---------------------------------------------------------------------------

/// Connecting to the WebSocket delivers an initial `presence` event to other
/// online members, signalling the user is online.
#[tokio::test]
async fn connecting_broadcasts_online_presence_to_peer() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _, _) = common::register_and_login(&client, &base, "pres_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "pres_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice connects first.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    drain_pending(&mut alice_ws).await;

    // Bob connects — Alice should receive a presence event for Bob.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    // Alice waits for Bob's online presence.
    let timeout = std::time::Duration::from_secs(5);
    let mut got_presence = false;
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        match tokio::time::timeout_at(deadline, alice_ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                if let Ok(v) = serde_json::from_str::<Value>(&text)
                    && v["type"] == "presence"
                    && v["user_id"] == bob_id.as_str()
                {
                    got_presence = true;
                    break;
                }
            }
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(_))) | Ok(None) | Err(_) => break,
        }
    }

    assert!(
        got_presence,
        "Alice should receive an online presence event when Bob connects"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}
