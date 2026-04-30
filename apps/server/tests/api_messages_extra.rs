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

    // DMs are auto-encrypted at creation, so the ciphertext-shape gate (#591)
    // requires both a wire-shaped canonical content and per-recipient device
    // ciphertexts.
    let ct_alice = common::dummy_ciphertext("setup_dm_alice");
    let ct_bob = common::dummy_ciphertext("setup_dm_bob");
    ws.send(Message::Text(
        serde_json::json!({
            "type": "send_message",
            "to_user_id": bob_id,
            "conversation_id": conv_id,
            "content": ct_alice.clone(),
            "recipient_device_contents": {
                bob_id.to_string(): { "0": ct_bob },
                alice_id.to_string(): { "0": ct_alice },
            },
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

/// #582: editing on encrypted conversations would broadcast plaintext to
/// every member. The server must reject with 409 until per-device
/// ciphertext fanout for edits is implemented.
#[tokio::test]
async fn edit_message_on_encrypted_dm_returns_409() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm_with_message(&base).await;

    let resp = client
        .put(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "content": "Edited content" }))
        .send()
        .await
        .unwrap();

    assert_eq!(
        resp.status().as_u16(),
        409,
        "encrypted DMs must reject edits with 409 (#582)"
    );
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or_default()
            .to_lowercase()
            .contains("encrypted"),
        "error message should mention 'encrypted', got: {body:?}"
    );
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

    // Bob tries to edit Alice's message — should fail. Note: the encrypted-DM
    // gate (#582) now runs BEFORE the ownership check, so non-senders also
    // get 409 instead of 400 for encrypted conversations. Either is fine; we
    // just need to confirm the edit didn't succeed.
    let resp = client
        .put(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "content": "Bob's edit" }))
        .send()
        .await
        .unwrap();

    let status = resp.status().as_u16();
    assert!(
        status == 400 || status == 409,
        "expected 400/409, got {status}"
    );
}

/// #582: edits should still succeed for non-encrypted (legacy / group)
/// conversations so the rejection is scoped to the confidentiality hole.
#[tokio::test]
async fn edit_message_on_unencrypted_group_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "edit_pl_alice").await;

    // Groups default to `is_encrypted = false` so edits remain allowed.
    let group_id = common::create_group(&client, &base, &alice_token, "EditPlainGroup").await;

    // Send a plaintext message via WS.
    let ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let ws_url = base.replace("http://", "ws://");
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");
    tokio::time::sleep(Duration::from_millis(200)).await;
    while let Ok(Some(Ok(_))) = tokio::time::timeout(Duration::from_millis(100), ws.next()).await {}

    ws.send(Message::Text(
        serde_json::json!({
            "type": "send_message",
            "conversation_id": group_id,
            "content": "Plain group message",
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

    let resp = client
        .put(format!("{base}/api/messages/{message_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "content": "Edited plain content" }))
        .send()
        .await
        .unwrap();

    assert_eq!(
        resp.status().as_u16(),
        200,
        "edits on non-encrypted conversations must still succeed"
    );
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

/// Search returns 200 and an array (possibly empty) for member queries.
/// Server-side full-text search across encrypted ciphertext is mostly a
/// no-op now that the gate (#591) requires wire-shaped content; but the
/// route must still answer cleanly. (Pre-#591 this asserted a hit on the
/// plaintext message we used to send.)
#[tokio::test]
async fn search_messages_returns_array_for_member() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, conv_id, _) = setup_dm_with_message(&base).await;

    let resp = client
        .get(format!("{base}/api/conversations/{conv_id}/search?q=setup"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let _results: Vec<Value> = resp.json().await.unwrap();
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

// ---------------------------------------------------------------------------
// Offline replay regression for #557
// ---------------------------------------------------------------------------

mod offline_replay_557 {
    use super::*;
    use tokio_tungstenite::tungstenite::Message as WsMsg;

    type WsStream = tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >;

    async fn connect_ws_with_ticket(base: &str, ticket: &str) -> WsStream {
        let ws_base = base.replace("http://", "ws://");
        let (ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
            .await
            .expect("WS connect failed");
        ws
    }

    /// Read up to N text frames from the socket within a small budget,
    /// skipping presence noise, returning all decoded JSON values.
    async fn collect_text_frames(ws: &mut WsStream, max: usize) -> Vec<Value> {
        let timeout = Duration::from_millis(1500);
        let mut out = Vec::new();
        for _ in 0..max {
            match tokio::time::timeout(timeout, ws.next()).await {
                Ok(Some(Ok(WsMsg::Text(text)))) => {
                    if let Ok(v) = serde_json::from_str::<Value>(&text) {
                        if v["type"] == "presence" {
                            continue;
                        }
                        out.push(v);
                    }
                }
                Ok(Some(Ok(WsMsg::Ping(_)))) | Ok(Some(Ok(WsMsg::Pong(_)))) => continue,
                _ => break,
            }
        }
        out
    }

    /// Bug #557 — when the offline queue holds a per-device fanout message but
    /// the reconnecting device has no row in `message_device_contents`, the
    /// pre-fix code returned the canonical (sender's) ciphertext, which the
    /// secondary device cannot decrypt.  After the fix the server emits an
    /// explicit `undecryptable: true` marker and leaves the message
    /// undelivered for a future reconnect.
    #[tokio::test]
    async fn test_offline_replay_skips_when_no_device_ciphertext() {
        let base = common::spawn_server().await;
        let client = Client::new();

        let (alice_token, _alice_id, _alice_name) =
            common::register_and_login(&client, &base, "rs1_alice").await;
        let (bob_token, bob_id, bob_name) =
            common::register_and_login(&client, &base, "rs1_bob").await;

        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

        // Alice connects on device 1 and sends a message with a per-device
        // ciphertext for Bob's device 11 ONLY.  Bob's device 22 is offline
        // and has no per-device row.
        let alice_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
        let mut alice_ws = connect_ws_with_ticket(&base, &alice_ticket).await;
        tokio::time::sleep(Duration::from_millis(150)).await;
        let _ = collect_text_frames(&mut alice_ws, 4).await; // drain presence

        let alice_wire = common::dummy_ciphertext("rs1_alice_wire");
        let bob_d11_ct = common::dummy_ciphertext("rs1_bob_d11");
        let send = serde_json::json!({
            "type": "send_message",
            "to_user_id": bob_id,
            "content": alice_wire.clone(),
            "recipient_device_contents": {
                bob_id.to_string(): { "11": bob_d11_ct },
            },
        });
        alice_ws
            .send(WsMsg::Text(send.to_string().into()))
            .await
            .unwrap();
        let _ = collect_text_frames(&mut alice_ws, 2).await;

        // Bob comes online on device 22 — this device has NO per-device row.
        let bob_d22_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 22).await;
        let mut bob_d22 = connect_ws_with_ticket(&base, &bob_d22_ticket).await;

        let frames = collect_text_frames(&mut bob_d22, 4).await;
        let new_msgs: Vec<&Value> = frames
            .iter()
            .filter(|v| v["type"] == "new_message")
            .collect();
        assert_eq!(
            new_msgs.len(),
            1,
            "Bob should receive exactly one replay frame, got: {frames:?}"
        );
        let m = new_msgs[0];
        assert_eq!(
            m["undecryptable"], true,
            "device 22 has no per-device row -> must be marked undecryptable"
        );
        // Pre-fix bug shipped Alice's ciphertext here. The fix MUST NOT leak it.
        assert_ne!(
            m["content"], alice_wire,
            "must not return canonical sender ciphertext to wrong device"
        );

        let _ = alice_ws.close(None).await;
        let _ = bob_d22.close(None).await;
    }

    /// Bug #557 — replay frames must propagate the originating device id so
    /// the recipient can decrypt with the correct per-device ratchet.
    #[tokio::test]
    async fn test_offline_replay_includes_from_device_id() {
        let base = common::spawn_server().await;
        let client = Client::new();

        let (alice_token, _alice_id, _alice_name) =
            common::register_and_login(&client, &base, "rs2_alice").await;
        let (bob_token, bob_id, bob_name) =
            common::register_and_login(&client, &base, "rs2_bob").await;

        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

        let alice_device_id: i32 = 7;
        let bob_device_id: i32 = 11;

        // Alice (device 7) sends a per-device frame for Bob's device 11.
        let alice_ticket =
            common::get_ws_ticket_for_device(&client, &base, &alice_token, alice_device_id).await;
        let mut alice_ws = connect_ws_with_ticket(&base, &alice_ticket).await;
        tokio::time::sleep(Duration::from_millis(150)).await;
        let _ = collect_text_frames(&mut alice_ws, 4).await;

        let canonical = common::dummy_ciphertext("rs2_canonical");
        let bob_replay_ct = common::dummy_ciphertext("rs2_bob_replay");
        let send = serde_json::json!({
            "type": "send_message",
            "to_user_id": bob_id,
            "content": canonical,
            "recipient_device_contents": {
                bob_id.to_string(): { bob_device_id.to_string(): bob_replay_ct.clone() },
            },
        });
        alice_ws
            .send(WsMsg::Text(send.to_string().into()))
            .await
            .unwrap();
        let _ = collect_text_frames(&mut alice_ws, 2).await;

        // Bob comes online on device 11.
        let bob_ticket =
            common::get_ws_ticket_for_device(&client, &base, &bob_token, bob_device_id).await;
        let mut bob_ws = connect_ws_with_ticket(&base, &bob_ticket).await;
        let frames = collect_text_frames(&mut bob_ws, 4).await;
        let m = frames
            .iter()
            .find(|v| v["type"] == "new_message")
            .expect("expected a replay new_message");
        assert_eq!(m["content"], bob_replay_ct);
        assert_eq!(
            m["from_device_id"].as_i64(),
            Some(alice_device_id as i64),
            "replay frame must surface sender device id (#557)"
        );

        let _ = alice_ws.close(None).await;
        let _ = bob_ws.close(None).await;
    }
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

// ---------------------------------------------------------------------------
// Device-aware history regression for #557 (Bug 3)
// ---------------------------------------------------------------------------

mod history_device_aware_557 {
    use super::*;
    use tokio_tungstenite::tungstenite::Message as WsMsg;

    /// Bug #557 — `GET /api/messages/:conv_id?device_id=N` must LEFT JOIN
    /// `message_device_contents` and return the per-device ciphertext for the
    /// requesting (recipient_user, device_id) pair.  Without `device_id` the
    /// legacy canonical content is preserved for backward compat.
    #[tokio::test]
    async fn test_get_messages_returns_device_specific_ciphertext() {
        let base = common::spawn_server().await;
        let client = Client::new();

        let (alice_token, _alice_id, _alice_name) =
            common::register_and_login(&client, &base, "hda_alice").await;
        let (bob_token, bob_id, bob_name) =
            common::register_and_login(&client, &base, "hda_bob").await;

        let conv_id =
            common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name)
                .await;

        let alice_device_id: i32 = 7;
        let alice_ticket =
            common::get_ws_ticket_for_device(&client, &base, &alice_token, alice_device_id).await;
        let ws_url = base.replace("http://", "ws://");
        let (mut alice_ws, _) =
            tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={alice_ticket}"))
                .await
                .expect("WS connect failed");

        tokio::time::sleep(Duration::from_millis(150)).await;
        while let Ok(Some(Ok(_))) =
            tokio::time::timeout(Duration::from_millis(100), alice_ws.next()).await
        {}

        let canon_ct = common::dummy_ciphertext("hist_canon");
        let ct_d11 = common::dummy_ciphertext("hist_d11");
        let ct_d22 = common::dummy_ciphertext("hist_d22");
        alice_ws
            .send(WsMsg::Text(
                serde_json::json!({
                    "type": "send_message",
                    "to_user_id": bob_id,
                    "conversation_id": conv_id,
                    "content": canon_ct.clone(),
                    "recipient_device_contents": {
                        bob_id.to_string(): {
                            "11": ct_d11.clone(),
                            "22": ct_d22.clone(),
                        },
                    },
                })
                .to_string()
                .into(),
            ))
            .await
            .unwrap();

        // Wait for message_sent ack so the row is committed before history reads.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while let Ok(Some(Ok(WsMsg::Text(text)))) =
            tokio::time::timeout_at(deadline, alice_ws.next()).await
        {
            if let Ok(json) = serde_json::from_str::<Value>(&text)
                && json["type"] == "message_sent"
            {
                break;
            }
        }
        let _ = alice_ws.close(None).await;

        // Device 11 -> CT_D11 + from_device_id == alice_device_id
        let resp_d11: Value = client
            .get(format!("{base}/api/messages/{conv_id}?device_id=11"))
            .header("Authorization", format!("Bearer {bob_token}"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let last_d11 = resp_d11
            .as_array()
            .expect("history is an array")
            .last()
            .expect("at least one message")
            .clone();
        assert_eq!(
            last_d11["content"], ct_d11,
            "device 11 should receive its per-device ciphertext"
        );
        assert_eq!(
            last_d11["from_device_id"].as_i64(),
            Some(alice_device_id as i64),
            "history rows must surface sender device id"
        );

        // Device 22 -> CT_D22 (different ciphertext, same message)
        let resp_d22: Value = client
            .get(format!("{base}/api/messages/{conv_id}?device_id=22"))
            .header("Authorization", format!("Bearer {bob_token}"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let last_d22 = resp_d22.as_array().unwrap().last().unwrap().clone();
        assert_eq!(
            last_d22["content"], ct_d22,
            "device 22 should receive its OWN per-device ciphertext, not device 11's"
        );

        // No device_id -> legacy canonical fallback (backward compat for old clients).
        let resp_legacy: Value = client
            .get(format!("{base}/api/messages/{conv_id}"))
            .header("Authorization", format!("Bearer {bob_token}"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let last_legacy = resp_legacy.as_array().unwrap().last().unwrap().clone();
        assert_eq!(
            last_legacy["content"], canon_ct,
            "no device_id param -> legacy canonical content (backward compat)"
        );
    }

    /// Bug #557 — even though the route accepts `device_id`, the per-device
    /// JOIN must be bound to the authenticated user's id, NOT the param,
    /// so a non-member of the conversation cannot retrieve any per-device
    /// ciphertext by guessing device ids.
    #[tokio::test]
    async fn test_get_messages_rejects_non_member_with_device_id() {
        let base = common::spawn_server().await;
        let client = Client::new();

        let (alice_token, _alice_id, _alice_name) =
            common::register_and_login(&client, &base, "auz_alice").await;
        let (bob_token, bob_id, bob_name) =
            common::register_and_login(&client, &base, "auz_bob").await;
        let (carol_token, _carol_id, _carol_name) =
            common::register_and_login(&client, &base, "auz_carol").await;

        let conv_id =
            common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name)
                .await;

        // Carol (not a member of Alice <-> Bob's DM) tries to read history
        // with a guessed device_id.  Auth gate must reject regardless.
        let status = client
            .get(format!("{base}/api/messages/{conv_id}?device_id=11"))
            .header("Authorization", format!("Bearer {carol_token}"))
            .send()
            .await
            .unwrap()
            .status();
        assert!(
            !status.is_success(),
            "non-member must not access conversation history (got {status})"
        );
    }
}
