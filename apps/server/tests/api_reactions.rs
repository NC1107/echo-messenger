//! Integration tests for reaction and read-receipt endpoints.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

/// Helper: register a user, log in, and return (token, user_id, username).
async fn register_and_login(client: &Client, base: &str, prefix: &str) -> (String, String, String) {
    let username = common::unique_username(prefix);
    common::register(client, base, &username, "password123").await;
    let (token, user_id) = common::login(client, base, &username, "password123").await;
    (token, user_id, username)
}

/// Set up two users as contacts, create a DM, send a message via WS.
/// Returns (client, alice_token, alice_id, bob_token, conv_id, message_id).
async fn setup_dm_with_message(base: &str) -> (Client, String, String, String, String, String) {
    let client = Client::new();
    let (alice_token, alice_id, _) = register_and_login(&client, base, "rxn_alice").await;
    let (bob_token, bob_id, bob_name) = register_and_login(&client, base, "rxn_bob").await;

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
        .json(&serde_json::json!({ "peer_user_id": bob_id }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let conv_id = body["conversation_id"].as_str().unwrap().to_string();

    // Send a message via WS to get a real message_id
    let ticket = common::get_ws_ticket(&client, base, &alice_token).await;
    let ws_url = base.replace("http://", "ws://");
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Drain initial presence/contact events so they don't interfere with the
    // message_sent assertion below. The 100ms timeout means we stop draining
    // once there are no more pending messages.
    while let Ok(Some(Ok(_))) = tokio::time::timeout(Duration::from_millis(100), ws.next()).await {}

    ws.send(Message::Text(
        serde_json::json!({
            "type": "send_message",
            "to_user_id": bob_id,
            "conversation_id": conv_id,
            "content": "React to me!",
        })
        .to_string()
        .into(),
    ))
    .await
    .unwrap();

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

    assert!(!message_id.is_empty(), "should have received message_id");

    (
        client,
        alice_token,
        alice_id,
        bob_token,
        conv_id,
        message_id,
    )
}

// ---------------------------------------------------------------------------
// Add reaction
// ---------------------------------------------------------------------------

#[tokio::test]
async fn add_reaction_returns_201() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/reactions"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "emoji": "👍" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["reaction_id"].as_str().is_some(),
        "should return reaction_id"
    );
}

#[tokio::test]
async fn add_reaction_empty_emoji_returns_400() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/reactions"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "emoji": "" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn add_reaction_non_member_returns_401() {
    let base = common::spawn_server().await;
    let (client, _, _, _, _, message_id) = setup_dm_with_message(&base).await;

    // Stranger has no access to this DM
    let (stranger_token, _, _) = register_and_login(&client, &base, "rxn_stranger").await;

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/reactions"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .json(&serde_json::json!({ "emoji": "❤️" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn add_reaction_invalid_message_returns_400() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _) = setup_dm_with_message(&base).await;

    let fake_id = uuid::Uuid::new_v4();
    let resp = client
        .post(format!("{base}/api/messages/{fake_id}/reactions"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "emoji": "👍" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Remove reaction
// ---------------------------------------------------------------------------

#[tokio::test]
async fn remove_reaction_succeeds() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, message_id) = setup_dm_with_message(&base).await;

    // Add a reaction first
    client
        .post(format!("{base}/api/messages/{message_id}/reactions"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "emoji": "🎉" }))
        .send()
        .await
        .unwrap();

    // reqwest uses the `url` crate which automatically percent-encodes non-ASCII
    // characters in path segments, so the emoji is correctly encoded on the wire.
    let emoji = "🎉";
    let resp = client
        .delete(format!(
            "{base}/api/messages/{message_id}/reactions/{emoji}"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "removed");
}

#[tokio::test]
async fn remove_nonexistent_reaction_returns_400() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .delete(format!("{base}/api/messages/{message_id}/reactions/🤔"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Mark read
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mark_read_returns_200() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let resp = client
        .post(format!("{base}/api/conversations/{conv_id}/read"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn mark_read_non_member_returns_401() {
    let base = common::spawn_server().await;
    let (client, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let (stranger_token, _, _) = register_and_login(&client, &base, "rxn_readstranger").await;

    let resp = client
        .post(format!("{base}/api/conversations/{conv_id}/read"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn mark_read_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let fake_id = uuid::Uuid::new_v4();

    let resp = client
        .post(format!("{base}/api/conversations/{fake_id}/read"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}
