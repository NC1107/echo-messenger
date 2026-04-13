//! Integration tests for group channel management endpoints.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Helper: register a user, log in, and return (token, user_id).
async fn register_and_login(client: &Client, base: &str, prefix: &str) -> (String, String) {
    let username = common::unique_username(prefix);
    common::register(client, base, &username, "password123").await;
    common::login(client, base, &username, "password123").await
}

/// Helper: create a group and return (group_id, token).
async fn setup_group(client: &Client, base: &str, name: &str) -> (String, String) {
    let (token, _) = register_and_login(client, base, "chanown").await;
    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let group_id = body["id"].as_str().unwrap().to_string();
    (group_id, token)
}

// ---------------------------------------------------------------------------
// List channels
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_channels_returns_default_channels() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "ListChanGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let channels: Vec<Value> = resp.json().await.unwrap();
    // Server creates "general" (text) and "lounge" (voice) by default
    assert!(
        channels.len() >= 2,
        "should have at least 2 default channels"
    );
    assert!(
        channels.iter().any(|c| c["name"] == "general"),
        "should have 'general' text channel"
    );
    assert!(
        channels.iter().any(|c| c["name"] == "lounge"),
        "should have 'lounge' voice channel"
    );
}

#[tokio::test]
async fn list_channels_non_member_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, _) = setup_group(&client, &base, "ListChanPriv").await;
    let (stranger_token, _) = register_and_login(&client, &base, "chanstranger").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Create channel
// ---------------------------------------------------------------------------

#[tokio::test]
async fn owner_can_create_text_channel() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "CreateChanGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "announcements", "kind": "text" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["name"], "announcements");
    assert_eq!(body["kind"], "text");
}

#[tokio::test]
async fn owner_can_create_voice_channel() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "CreateVoiceGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "gaming", "kind": "voice" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["kind"], "voice");
}

#[tokio::test]
async fn create_channel_invalid_kind_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "BadKindGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "bad-channel", "kind": "invalid" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn create_channel_empty_name_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "EmptyNameGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "   ", "kind": "text" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn regular_member_cannot_create_channel() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, owner_token) = setup_group(&client, &base, "MemberChanGroup").await;
    let (member_token, member_id) = register_and_login(&client, &base, "chanmem").await;

    // Owner adds member
    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    // Member tries to create channel
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {member_token}"))
        .json(&serde_json::json!({ "name": "forbidden", "kind": "text" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn duplicate_channel_name_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "DupChanGroup").await;

    client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "duplicate", "kind": "text" }))
        .send()
        .await
        .unwrap();

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "duplicate", "kind": "text" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 409);
}

// ---------------------------------------------------------------------------
// Update channel
// ---------------------------------------------------------------------------

#[tokio::test]
async fn owner_can_update_channel() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "UpdateChanGroup").await;

    // Create a channel
    let create_resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "update-me", "kind": "text" }))
        .send()
        .await
        .unwrap();
    let create_body: Value = create_resp.json().await.unwrap();
    let channel_id = create_body["id"].as_str().unwrap().to_string();

    let resp = client
        .put(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "updated-name", "topic": "new topic" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["name"], "updated-name");
    assert_eq!(body["topic"], "new topic");
}

// ---------------------------------------------------------------------------
// Delete channel
// ---------------------------------------------------------------------------

#[tokio::test]
async fn owner_can_delete_channel() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "DeleteChanGroup").await;

    let create_resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "delete-me", "kind": "text" }))
        .send()
        .await
        .unwrap();
    let create_body: Value = create_resp.json().await.unwrap();
    let channel_id = create_body["id"].as_str().unwrap().to_string();

    let resp = client
        .delete(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 204);
}

// ---------------------------------------------------------------------------
// Channel name normalisation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn channel_name_is_normalised_to_lowercase_hyphenated() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, token) = setup_group(&client, &base, "NormChanGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "My Cool Channel", "kind": "text" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["name"], "my-cool-channel");
}
