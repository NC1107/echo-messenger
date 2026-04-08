//! Integration tests for the voice token endpoint.
//!
//! Validates identity checks and conversation membership authorization
//! introduced by the P0 security fixes.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Voice token with default identity (username) passes validation.
/// Since LIVEKIT_API_KEY is not set in tests, the request reaches the
/// "Voice chat is not configured" error, proving identity validation passed.
#[tokio::test]
async fn voice_token_default_identity_passes_validation() {
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

    // Reaches the LIVEKIT_API_KEY check (identity validation passed)
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

    let name = common::unique_username("voice");
    common::register(&client, &base, &name, "password123").await;
    let (token, user_id) = common::login(&client, &base, &name, "password123").await;

    let resp = client
        .post(format!("{base}/api/voice/token"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "room": "test-room", "identity": user_id }))
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

/// Voice token with empty room is rejected.
#[tokio::test]
async fn voice_token_empty_room_rejected() {
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
            .contains("Room name is required")
    );
}
