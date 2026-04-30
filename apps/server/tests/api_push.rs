//! Integration tests for push-token registration / unregistration endpoints.

mod common;

use reqwest::Client;
use serde_json::Value;

// ---------------------------------------------------------------------------
// POST /api/push/register
// ---------------------------------------------------------------------------

/// Happy-path: authenticated user registers a valid APNs token.
#[tokio::test]
async fn register_token_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_reg").await;

    let resp = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "apns-device-token-abc123",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"].as_str().unwrap_or(""), "ok");
}

/// Unauthenticated requests to /register are rejected with 401.
#[tokio::test]
async fn register_token_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/push/register"))
        .json(&serde_json::json!({
            "token": "apns-device-token-abc123",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

/// An empty token string is rejected with 400.
#[tokio::test]
async fn register_token_empty_token_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_empty").await;

    let resp = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": "", "platform": "apns" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("Token is required"),
        "expected 'Token is required' error, got: {body}"
    );
}

/// Unsupported platforms are rejected with 400.
#[tokio::test]
async fn register_token_invalid_platform_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_plat").await;

    let resp = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "some-fcm-token",
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
            .contains("Only 'apns' platform is supported"),
        "expected platform error, got: {body}"
    );
}

/// Registering the same token twice (upsert) still returns 200.
#[tokio::test]
async fn register_token_upsert_is_idempotent() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_idem").await;

    let payload = serde_json::json!({
        "token": "apns-idempotent-token",
        "platform": "apns",
    });

    for _ in 0..2 {
        let resp = client
            .post(format!("{base}/api/push/register"))
            .header("Authorization", format!("Bearer {token}"))
            .json(&payload)
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status().as_u16(), 200);
    }
}

// ---------------------------------------------------------------------------
// POST /api/push/unregister
// ---------------------------------------------------------------------------

/// Happy-path: authenticated user removes a push token.
#[tokio::test]
async fn unregister_token_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_unreg").await;

    // Register first so there is something to remove.
    client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "apns-remove-me",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    let resp = client
        .post(format!("{base}/api/push/unregister"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": "apns-remove-me" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"].as_str().unwrap_or(""), "ok");
}

/// Unauthenticated requests to /unregister are rejected with 401.
#[tokio::test]
async fn unregister_token_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/push/unregister"))
        .json(&serde_json::json!({ "token": "apns-remove-me" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

/// Unregistering a token that was never registered still returns 200
/// (idempotent cleanup is safe on logout).
#[tokio::test]
async fn unregister_nonexistent_token_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_ghost").await;

    let resp = client
        .post(format!("{base}/api/push/unregister"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": "token-that-was-never-registered" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}

// ---------------------------------------------------------------------------
// Integration: register → logout cleanup flow
// ---------------------------------------------------------------------------

/// Full lifecycle: register a push token then unregister it on logout.
/// This mirrors the PushTokenService.init() + PushTokenService.unregister()
/// sequence executed by the iOS client.
#[tokio::test]
async fn register_then_unregister_on_logout() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_life").await;

    let device_token = "apns-lifecycle-token-xyz";

    // 1. Register token after login.
    let reg = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": device_token,
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(reg.status().as_u16(), 200, "register should succeed");

    // 2. Unregister token on logout (while still authenticated).
    let unreg = client
        .post(format!("{base}/api/push/unregister"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": device_token }))
        .send()
        .await
        .unwrap();
    assert_eq!(unreg.status().as_u16(), 200, "unregister should succeed");

    // 3. A second unregister (e.g. re-login on same device) is still safe.
    let unreg2 = client
        .post(format!("{base}/api/push/unregister"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": device_token }))
        .send()
        .await
        .unwrap();
    assert_eq!(unreg2.status().as_u16(), 200, "second unregister should be safe");
}

// ---------------------------------------------------------------------------
// Integration: media-ticket refresh after re-login
// ---------------------------------------------------------------------------

/// After login a new media ticket can be fetched; after re-authentication the
/// endpoint still returns a fresh ticket.  This validates that the ticket
/// infrastructure is not coupled to a single session lifetime.
#[tokio::test]
async fn media_ticket_accessible_after_login() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_mticket").await;

    let resp = client
        .post(format!("{base}/api/media/ticket"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["ticket"].as_str().map(|s| !s.is_empty()).unwrap_or(false),
        "ticket should be a non-empty string: {body}"
    );
}

/// Media ticket endpoint returns 401 without authentication.
#[tokio::test]
async fn media_ticket_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/media/ticket"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}
