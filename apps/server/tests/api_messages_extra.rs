//! Integration tests for message edit, delete, search, mute, and conversation listing.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

/// Set up two users as contacts with a DM and a sent message.
/// Returns (client, alice_token, alice_id, bob_token, bob_id, conv_id, message_id).
#[allow(clippy::type_complexity)]
async fn setup_dm_with_message(
    base: &str,
) -> (Client, String, String, String, String, String, String) {
    let client = Client::new();
    let alice_name = common::unique_username("msg_alice");
    let bob_name = common::unique_username("msg_bob");

    common::register(&client, base, &alice_name, "password123").await;
    common::register(&client, base, &bob_name, "password123").await;

    let (alice_token, alice_id) = common::login(&client, base, &alice_name, "password123").await;
    let (bob_token, bob_id) = common::login(&client, base, &bob_name, "password123").await;

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

    // Send message via WS
    let ticket = common::get_ws_ticket(&client, base, &alice_token).await;
    let ws_url = base.replace("http://", "ws://");
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Drain initial events
    while let Ok(Some(Ok(_))) = tokio::time::timeout(Duration::from_millis(100), ws.next()).await {}

    ws.send(Message::Text(
        serde_json::json!({
            "type": "send_message",
            "to_user_id": bob_id,
            "conversation_id": conv_id,
            "content": "Original content",
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
        bob_id,
        conv_id,
        message_id,
    )
}

// ---------------------------------------------------------------------------
// Edit message
// ---------------------------------------------------------------------------

#[tokio::test]
async fn edit_own_message_succeeds() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .put(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "content": "Edited content" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["message_id"].as_str(), Some(message_id.as_str()));
    assert!(body["edited_at"].is_string());
}

#[tokio::test]
async fn edit_message_empty_content_returns_400() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .put(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "content": "" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn edit_someone_elses_message_returns_400() {
    let base = common::spawn_server().await;
    let (client, _, _, bob_token, _, _, message_id) = setup_dm_with_message(&base).await;

    // Bob tries to edit Alice's message — should fail
    let resp = client
        .put(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "content": "Bob's edit" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn edit_nonexistent_message_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("editunk");
    common::register(&client, &base, &username, "password123").await;
    let (token, _) = common::login(&client, &base, &username, "password123").await;

    let fake_id = uuid::Uuid::new_v4();
    let resp = client
        .put(format!("{base}/api/messages/{fake_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "content": "Hello" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Delete message
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_own_message_returns_204() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .delete(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 204);
}

#[tokio::test]
async fn delete_someone_elses_message_returns_400() {
    let base = common::spawn_server().await;
    let (client, _, _, bob_token, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .delete(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn delete_nonexistent_message_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("delunk");
    common::register(&client, &base, &username, "password123").await;
    let (token, _) = common::login(&client, &base, &username, "password123").await;

    let fake_id = uuid::Uuid::new_v4();
    let resp = client
        .delete(format!("{base}/api/messages/{fake_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// List conversations
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_conversations_returns_dm() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let resp = client
        .get(format!("{base}/api/conversations"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let convs: Vec<Value> = resp.json().await.unwrap();
    assert!(
        convs
            .iter()
            .any(|c| c["conversation_id"].as_str() == Some(&conv_id)),
        "DM conversation should appear in the list"
    );
}

#[tokio::test]
async fn list_conversations_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/conversations"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Get messages (paginated)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_messages_returns_sent_message() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, conv_id, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .get(format!("{base}/api/messages/{conv_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let messages: Vec<Value> = resp.json().await.unwrap();
    assert!(
        messages.iter().any(|m| {
            m["message_id"].as_str() == Some(&message_id) || m["id"].as_str() == Some(&message_id)
        }),
        "sent message should be in the conversation's message list"
    );
}

#[tokio::test]
async fn get_messages_non_member_returns_401() {
    let base = common::spawn_server().await;
    let (client, _, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let stranger_name = common::unique_username("msgstranger");
    common::register(&client, &base, &stranger_name, "password123").await;
    let (stranger_token, _) = common::login(&client, &base, &stranger_name, "password123").await;

    let resp = client
        .get(format!("{base}/api/messages/{conv_id}"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Toggle mute
// ---------------------------------------------------------------------------

#[tokio::test]
async fn toggle_mute_conversation_succeeds() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let resp = client
        .put(format!("{base}/api/conversations/{conv_id}/mute"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "is_muted": true }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["is_muted"], true);
}

#[tokio::test]
async fn toggle_mute_unmute_succeeds() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    // Mute
    client
        .put(format!("{base}/api/conversations/{conv_id}/mute"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "is_muted": true }))
        .send()
        .await
        .unwrap();

    // Unmute
    let resp = client
        .put(format!("{base}/api/conversations/{conv_id}/mute"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "is_muted": false }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["is_muted"], false);
}

/// Asserts that `get_unmuted_user_ids` excludes a member who muted the
/// conversation. This is the helper the push-notification path uses to drop
/// muted recipients before sending APNs alerts.
#[tokio::test]
async fn get_unmuted_user_ids_excludes_muted_member() {
    use uuid::Uuid;

    let base = common::spawn_server().await;
    let (client, alice_token, alice_id, _, bob_id, conv_id, _) = setup_dm_with_message(&base).await;

    // Alice mutes the conversation; Bob does not.
    let resp = client
        .put(format!("{base}/api/conversations/{conv_id}/mute"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "is_muted": true }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Open a direct DB connection to invoke the helper under test.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;

    let conv_uuid = Uuid::parse_str(&conv_id).unwrap();
    let alice_uuid = Uuid::parse_str(&alice_id).unwrap();
    let bob_uuid = Uuid::parse_str(&bob_id).unwrap();

    let unmuted =
        echo_server::db::messages::get_unmuted_user_ids(&pool, conv_uuid, &[alice_uuid, bob_uuid])
            .await
            .expect("get_unmuted_user_ids should succeed");

    assert!(
        !unmuted.contains(&alice_uuid),
        "muted user (alice) should be excluded"
    );
    assert!(
        unmuted.contains(&bob_uuid),
        "unmuted user (bob) should be included"
    );
}

// ---------------------------------------------------------------------------
// Search messages
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_messages_finds_content() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let resp = client
        .get(format!(
            "{base}/api/conversations/{conv_id}/search?q=Original"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let results: Vec<Value> = resp.json().await.unwrap();
    assert!(
        !results.is_empty(),
        "search for 'Original' should find the message"
    );
}

#[tokio::test]
async fn search_messages_non_member_returns_401() {
    let base = common::spawn_server().await;
    let (client, _, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let stranger_name = common::unique_username("srchstranger");
    common::register(&client, &base, &stranger_name, "password123").await;
    let (stranger_token, _) = common::login(&client, &base, &stranger_name, "password123").await;

    let resp = client
        .get(format!(
            "{base}/api/conversations/{conv_id}/search?q=Original"
        ))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Create DM
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_dm_idempotent() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, bob_id, conv_id, _) = setup_dm_with_message(&base).await;

    // Creating the same DM again should return the existing conversation
    let resp = client
        .post(format!("{base}/api/conversations/dm"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "peer_user_id": bob_id }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(
        body["conversation_id"].as_str(),
        Some(conv_id.as_str()),
        "Should return same conversation_id"
    );
}

#[tokio::test]
async fn create_dm_with_non_contact_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let alice_name = common::unique_username("dmnc_alice");
    let bob_name = common::unique_username("dmnc_bob");

    common::register(&client, &base, &alice_name, "password123").await;
    common::register(&client, &base, &bob_name, "password123").await;

    let (alice_token, _) = common::login(&client, &base, &alice_name, "password123").await;
    let (_, bob_id) = common::login(&client, &base, &bob_name, "password123").await;

    // Alice and Bob are NOT contacts
    let resp = client
        .post(format!("{base}/api/conversations/dm"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "peer_user_id": bob_id }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}
