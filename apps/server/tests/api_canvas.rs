//! Integration tests for the voice-lounge canvas endpoints.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Register a user, create a group, find the default "lounge" voice channel,
/// and return `(group_id, lounge_channel_id, token)`.
async fn setup_group_with_lounge(client: &Client, base: &str) -> (String, String, String) {
    let username = common::unique_username("canvas");
    common::register(client, base, &username, "password123").await;
    let (token, _) = common::login(client, base, &username, "password123").await;

    let group_id = common::create_group(client, base, &token, "CanvasTestGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let channels: Vec<Value> = resp.json().await.unwrap();

    let lounge = channels
        .iter()
        .find(|c| c["name"] == "lounge")
        .expect("default lounge voice channel should exist");
    let channel_id = lounge["id"].as_str().unwrap().to_string();

    (group_id, channel_id, token)
}

// ---------------------------------------------------------------------------
// GET canvas
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_canvas_returns_empty_for_new_channel() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, channel_id, token) = setup_group_with_lounge(&client, &base).await;

    let resp = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["channel_id"], channel_id);
    assert_eq!(body["drawing_data"], serde_json::json!([]));
    assert_eq!(body["images_data"], serde_json::json!([]));
}

// ---------------------------------------------------------------------------
// DELETE canvas
// ---------------------------------------------------------------------------

#[tokio::test]
async fn clear_canvas_returns_204() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, channel_id, token) = setup_group_with_lounge(&client, &base).await;

    let resp = client
        .delete(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 204);

    // Verify GET still returns empty arrays after clear
    let resp = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["drawing_data"], serde_json::json!([]));
    assert_eq!(body["images_data"], serde_json::json!([]));
}

// ---------------------------------------------------------------------------
// Auth required
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_canvas_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, channel_id, _) = setup_group_with_lounge(&client, &base).await;

    let resp = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn clear_canvas_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, channel_id, _) = setup_group_with_lounge(&client, &base).await;

    let resp = client
        .delete(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Non-existent channel
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_canvas_nonexistent_channel_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, _, token) = setup_group_with_lounge(&client, &base).await;
    let fake_channel = uuid::Uuid::new_v4();

    let resp = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{fake_channel}/canvas"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    let msg = body["error"].as_str().unwrap_or("");
    assert!(
        msg.contains("Channel not found"),
        "expected 'Channel not found', got: {msg}"
    );
}

// ---------------------------------------------------------------------------
// Non-member access
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_canvas_non_member_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, channel_id, _) = setup_group_with_lounge(&client, &base).await;

    let (stranger_token, _, _) = common::register_and_login(&client, &base, "canvasstranger").await;

    let resp = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn clear_canvas_non_member_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (group_id, channel_id, _) = setup_group_with_lounge(&client, &base).await;

    let (stranger_token, _, _) =
        common::register_and_login(&client, &base, "canvasstranger2").await;

    let resp = client
        .delete(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Channel belongs to wrong group
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_canvas_channel_wrong_group() {
    let base = common::spawn_server().await;
    let client = Client::new();

    // Group A with its lounge channel
    let (_, channel_a, token) = setup_group_with_lounge(&client, &base).await;

    // Group B (same user, different group)
    let group_b = common::create_group(&client, &base, &token, "CanvasGroupB").await;

    // Try to access group A's channel via group B's URL
    let resp = client
        .get(format!(
            "{base}/api/groups/{group_b}/channels/{channel_a}/canvas"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    let msg = body["error"].as_str().unwrap_or("");
    assert!(
        msg.contains("Channel does not belong to this group"),
        "expected 'Channel does not belong to this group', got: {msg}"
    );
}
