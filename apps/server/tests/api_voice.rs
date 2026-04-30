//! Integration tests for the voice token endpoint.
//!
//! Validates identity checks and conversation membership authorization
//! introduced by the P0 security fixes.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Helper: create two users, make them contacts, create a DM, return (token_a, user_a_id, conv_id).
async fn setup_voice_test(client: &Client, base: &str) -> (String, String, String) {
    let name_a = common::unique_username("voice");
    let name_b = common::unique_username("voice");
    common::register(client, base, &name_a, "password123").await;
    common::register(client, base, &name_b, "password123").await;
    let (token_a, user_a_id) = common::login(client, base, &name_a, "password123").await;
    let (token_b, _) = common::login(client, base, &name_b, "password123").await;

    // Make them contacts
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {token_a}"))
        .json(&serde_json::json!({ "username": name_b }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().unwrap().to_string();

    let resp = client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {token_b}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Create DM conversation
    let peer_id = common::login(client, base, &name_b, "password123").await.1;
    let dm_resp = client
        .post(format!("{base}/api/conversations/dm"))
        .header("Authorization", format!("Bearer {token_a}"))
        .json(&serde_json::json!({ "peer_user_id": peer_id }))
        .send()
        .await
        .unwrap();
    let dm_body: Value = dm_resp.json().await.unwrap();
    let conv_id = dm_body["conversation_id"].as_str().unwrap().to_string();

    (token_a, user_a_id, conv_id)
}

/// Voice token with default identity (username) passes validation.
/// Since LIVEKIT_API_KEY is not set in tests, the request reaches the
/// "Voice chat is not configured" error, proving identity validation passed.
#[tokio::test]
async fn voice_token_default_identity_passes_validation() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, conv_id) = setup_voice_test(&client, &base).await;

    let resp = client
        .post(format!("{base}/api/voice/token"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "room": "test-room",
            "conversation_id": conv_id
        }))
        .send()
        .await
        .unwrap();

    // Reaches the LIVEKIT_API_KEY check (identity + membership validation passed)
    let body: Value = resp.json().await.unwrap();
    let error = body["error"].as_str().unwrap_or("");
    assert!(
        error.contains("Voice chat is not configured"),
        "Expected LIVEKIT config error, got: {error}"
    );
}

/// Voice token with explicit UUID identity passes validation (backward compat).
#[tokio::test]
async fn voice_token_uuid_identity_accepted() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, user_id, conv_id) = setup_voice_test(&client, &base).await;

    let resp = client
        .post(format!("{base}/api/voice/token"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "room": "test-room",
            "identity": user_id,
            "conversation_id": conv_id
        }))
        .send()
        .await
        .unwrap();

    let body: Value = resp.json().await.unwrap();
    let error = body["error"].as_str().unwrap_or("");
    assert!(
        error.contains("Voice chat is not configured"),
        "Expected LIVEKIT config error, got: {error}"
    );
}

/// Voice token with mismatched identity is rejected.
#[tokio::test]
async fn voice_token_wrong_identity_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let name = common::unique_username("voice");
    common::register(&client, &base, &name, "password123").await;
    let (token, _) = common::login(&client, &base, &name, "password123").await;

    let resp = client
        .post(format!("{base}/api/voice/token"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "room": "test-room", "identity": "impersonator" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("Identity must match")
    );
}

/// Voice token without conversation_id or channel_id is rejected.
#[tokio::test]
async fn voice_token_without_conversation_id_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let name = common::unique_username("voice");
    common::register(&client, &base, &name, "password123").await;
    let (token, _) = common::login(&client, &base, &name, "password123").await;

    let resp = client
        .post(format!("{base}/api/voice/token"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "room": "test-room" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("conversation_id or channel_id is required"),
    );
}

/// Voice token with empty body is rejected (no room can be derived).
///
/// After CRIT-1 the `room` field was removed from the request: rooms are
/// always derived from a verified-membership conversation_id/channel_id, so
/// the canonical "missing room" failure now surfaces as the missing
/// conversation_id error.
#[tokio::test]
async fn voice_token_empty_body_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let name = common::unique_username("voice");
    common::register(&client, &base, &name, "password123").await;
    let (token, _) = common::login(&client, &base, &name, "password123").await;

    let resp = client
        .post(format!("{base}/api/voice/token"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({}))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("conversation_id or channel_id is required"),
        "expected conversation-id error, got: {}",
        body
    );
}

/// CRIT-1 regression test: the `room` field on the request is silently
/// dropped now -- the LiveKit grant must always be derived from the
/// validated conversation_id, never an attacker-supplied value.  We assert
/// the request reaches the LIVEKIT-config error (i.e. validation passed)
/// even though we tried to set a different `room` than `conversation_id`.
#[tokio::test]
async fn voice_token_ignores_attacker_supplied_room() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, conv_id) = setup_voice_test(&client, &base).await;

    let resp = client
        .post(format!("{base}/api/voice/token"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            // An attacker tries to steer the room claim to a victim conv id.
            "room": "00000000-0000-0000-0000-000000000000",
            "conversation_id": conv_id,
        }))
        .send()
        .await
        .unwrap();

    let body: Value = resp.json().await.unwrap();
    let error = body["error"].as_str().unwrap_or("");
    assert!(
        error.contains("Voice chat is not configured"),
        "expected LIVEKIT config error (validation passed), got: {error}"
    );
}
