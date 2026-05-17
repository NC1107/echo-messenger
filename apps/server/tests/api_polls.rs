//! Integration tests for the polls-in-chat endpoints.
//!
//! Covers:
//!   POST /api/messages/:id/poll     -- create poll
//!   POST /api/messages/:id/poll/vote -- vote
//!   GET  /api/messages/:id/poll     -- read results
//!
//! Test users:
//!   alice -- poll creator
//!   bob   -- voter / non-member
//!   carol -- member who validates multi-voter tally

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------

/// Register a user, log in, and return (token, user_id, username).
async fn ral(client: &Client, base: &str, prefix: &str) -> (String, String, String) {
    common::register_and_login(client, base, prefix).await
}

/// Create a DM conversation between alice and bob and return
/// (conv_id, message_id) where message_id is a real WS-sent message.
async fn setup_dm(base: &str) -> (Client, String, String, String, String, String, String) {
    let client = Client::new();
    let (alice_token, alice_id, _alice_name) = ral(&client, base, "poll_alice").await;
    let (bob_token, bob_id, bob_name) = ral(&client, base, "poll_bob").await;

    let conv_id =
        common::make_contacts(&client, base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice sends a message via WS to get a real message_id.
    let ticket = common::get_ws_ticket(&client, base, &alice_token).await;
    let ws_url = base.replace("http://", "ws://");
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");

    // Drain initial chatter.
    while let Ok(Some(Ok(_))) = tokio::time::timeout(Duration::from_millis(120), ws.next()).await {}

    let ct = common::dummy_ciphertext("poll_setup");
    ws.send(Message::Text(
        serde_json::json!({
            "type": "send_message",
            "to_user_id": bob_id,
            "conversation_id": conv_id,
            "content": ct.clone(),
            "recipient_device_contents": {
                bob_id.to_string(): { "0": ct.clone() },
                alice_id.to_string(): { "0": ct },
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
            message_id = json["message_id"].as_str().unwrap_or("").to_string();
            break;
        }
    }
    let _ = ws.close(None).await;

    assert!(!message_id.is_empty(), "should have received a message_id");

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
// Create poll
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_poll_returns_201() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({
            "question": "Favourite colour?",
            "options": ["Red", "Green", "Blue"],
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201, "create poll should return 201");
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["message_id"].as_str().is_some(),
        "should return message_id"
    );
}

#[tokio::test]
async fn create_poll_duplicate_returns_409() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    let payload = serde_json::json!({
        "question": "Duplicate?",
        "options": ["Yes", "No"],
    });

    client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&payload)
        .send()
        .await
        .unwrap();

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&payload)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 409);
}

#[tokio::test]
async fn create_poll_too_few_options_returns_400() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({
            "question": "Lonely?",
            "options": ["Only one"],
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn create_poll_non_member_returns_401() {
    let base = common::spawn_server().await;
    let (client, _, _, _, _, _, message_id) = setup_dm(&base).await;

    let (stranger_token, _, _) = ral(&client, &base, "poll_stranger").await;

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .json(&serde_json::json!({
            "question": "Intruder?",
            "options": ["Yes", "No"],
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Get poll
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_poll_returns_question_and_zero_votes() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    // Create the poll first.
    client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({
            "question": "Cats or dogs?",
            "options": ["Cats", "Dogs", "Both"],
        }))
        .send()
        .await
        .unwrap();

    let resp = client
        .get(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["question"], "Cats or dogs?");
    let options = body["options"].as_array().unwrap();
    assert_eq!(options.len(), 3);
    assert_eq!(options[0]["count"], 0);
    assert_eq!(options[1]["count"], 0);
    assert!(body["my_vote"].is_null(), "no vote yet");
}

#[tokio::test]
async fn get_poll_missing_returns_404() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    let resp = client
        .get(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 404);
}

// ---------------------------------------------------------------------------
// Vote
// ---------------------------------------------------------------------------

#[tokio::test]
async fn vote_increments_count_and_records_my_vote() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    // Create poll.
    client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({
            "question": "Voting test?",
            "options": ["Aye", "Nay"],
        }))
        .send()
        .await
        .unwrap();

    // Alice votes option 0.
    let vote_resp = client
        .post(format!("{base}/api/messages/{message_id}/poll/vote"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "option_index": 0 }))
        .send()
        .await
        .unwrap();
    assert_eq!(vote_resp.status().as_u16(), 200);

    // Get results.
    let resp = client
        .get(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["options"][0]["count"], 1);
    assert_eq!(body["options"][1]["count"], 0);
    assert_eq!(body["my_vote"], 0);
}

#[tokio::test]
async fn vote_change_is_upserted() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({
            "question": "Change mind?",
            "options": ["First", "Second"],
        }))
        .send()
        .await
        .unwrap();

    // Vote option 0 then change to option 1.
    client
        .post(format!("{base}/api/messages/{message_id}/poll/vote"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "option_index": 0 }))
        .send()
        .await
        .unwrap();

    client
        .post(format!("{base}/api/messages/{message_id}/poll/vote"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "option_index": 1 }))
        .send()
        .await
        .unwrap();

    let resp = client
        .get(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    // Only the latest vote should count.
    assert_eq!(body["options"][0]["count"], 0, "old vote should be gone");
    assert_eq!(body["options"][1]["count"], 1, "new vote should register");
    assert_eq!(body["my_vote"], 1);
}

#[tokio::test]
async fn vote_out_of_range_returns_400() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, _, _, _, message_id) = setup_dm(&base).await;

    client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({
            "question": "Two options only",
            "options": ["A", "B"],
        }))
        .send()
        .await
        .unwrap();

    let resp = client
        .post(format!("{base}/api/messages/{message_id}/poll/vote"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "option_index": 99 }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn two_voters_tally_correctly() {
    let base = common::spawn_server().await;
    let (client, alice_token, _, bob_token, _, _, message_id) = setup_dm(&base).await;

    client
        .post(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({
            "question": "Multi voter?",
            "options": ["Option A", "Option B"],
        }))
        .send()
        .await
        .unwrap();

    // Alice votes A.
    client
        .post(format!("{base}/api/messages/{message_id}/poll/vote"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "option_index": 0 }))
        .send()
        .await
        .unwrap();

    // Bob votes B.
    client
        .post(format!("{base}/api/messages/{message_id}/poll/vote"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "option_index": 1 }))
        .send()
        .await
        .unwrap();

    let resp = client
        .get(format!("{base}/api/messages/{message_id}/poll"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["options"][0]["count"], 1, "alice voted A");
    assert_eq!(body["options"][1]["count"], 1, "bob voted B");
    // Voters list for A should include alice.
    let voters_a = body["options"][0]["voters"].as_array().unwrap();
    assert_eq!(voters_a.len(), 1);
}
