//! Integration tests for the push notification token endpoints.

mod common;

use reqwest::Client;
use serde_json::Value;

// ---------------------------------------------------------------------------
// POST /api/push/register
// ---------------------------------------------------------------------------

#[tokio::test]
async fn register_token_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_reg").await;

    let resp = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "device-push-token-abc123",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "ok");
}

#[tokio::test]
async fn register_token_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/push/register"))
        .json(&serde_json::json!({
            "token": "device-push-token-abc123",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn register_token_empty_token_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_empty").await;

    let resp = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn register_token_unsupported_platform_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_plat").await;

    let resp = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "device-push-token-abc123",
            "platform": "fcm",
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .to_lowercase()
            .contains("apns"),
        "error should mention supported platform: {body}"
    );
}

#[tokio::test]
async fn register_token_platform_case_insensitive() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_case").await;

    // "APNS" (uppercase) should be accepted (server lowercases the platform field)
    let resp = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "device-push-token-case",
            "platform": "APNS",
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}

// ---------------------------------------------------------------------------
// POST /api/push/unregister
// ---------------------------------------------------------------------------

#[tokio::test]
async fn unregister_token_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_unreg").await;

    // Register first
    client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "device-push-token-xyz",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    // Unregister
    let resp = client
        .post(format!("{base}/api/push/unregister"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": "device-push-token-xyz" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "ok");
}

#[tokio::test]
async fn unregister_token_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/push/unregister"))
        .json(&serde_json::json!({ "token": "device-push-token-xyz" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn unregister_nonexistent_token_still_returns_200() {
    // Unregistering a token that was never registered should not error --
    // idempotent delete semantics prevent noisy error logs on app reinstall.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_noop").await;

    let resp = client
        .post(format!("{base}/api/push/unregister"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": "token-that-was-never-registered" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}
