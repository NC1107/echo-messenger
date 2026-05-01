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
async fn delete_push_token_idempotent() {
    // The server-switching flow calls `DELETE /api/push/token` BEFORE the
    // URL flip; clients with no registered tokens (e.g. desktop/web) must
    // still get a 2xx so they can call it unconditionally.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_del").await;

    // First call -- nothing to delete, but still ok.
    let resp1 = client
        .delete(format!("{base}/api/push/token"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp1.status().as_u16(), 200);

    // Register a token, then delete -- should also succeed and clear it.
    client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "token": "tok-to-clear",
            "platform": "apns",
        }))
        .send()
        .await
        .unwrap();

    let resp2 = client
        .delete(format!("{base}/api/push/token"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp2.status().as_u16(), 200);

    // Idempotent: a second delete is also a 200.
    let resp3 = client
        .delete(format!("{base}/api/push/token"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp3.status().as_u16(), 200);
}

#[tokio::test]
async fn delete_push_token_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .delete(format!("{base}/api/push/token"))
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

// ---------------------------------------------------------------------------
// Upsert (duplicate token) -- #539
// ---------------------------------------------------------------------------

#[tokio::test]
async fn register_duplicate_token_upserts_no_constraint_violation() {
    // Registering the same (user, token) pair twice must not produce a 5xx
    // constraint violation -- the server upserts (ON CONFLICT DO UPDATE).
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_dup").await;

    let payload = serde_json::json!({
        "token": "device-token-duplicate-test",
        "platform": "apns",
    });

    // First registration.
    let r1 = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&payload)
        .send()
        .await
        .unwrap();
    assert_eq!(r1.status().as_u16(), 200, "first register must be 200");

    // Second registration with identical (user_id, token) -- should upsert.
    let r2 = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&payload)
        .send()
        .await
        .unwrap();
    assert_eq!(
        r2.status().as_u16(),
        200,
        "duplicate register must also be 200 (upsert)"
    );

    let body: Value = r2.json().await.unwrap();
    assert_eq!(body["status"], "ok");
}

// ---------------------------------------------------------------------------
// Logout cleanup -- #539
// ---------------------------------------------------------------------------

#[tokio::test]
async fn push_token_cleared_on_logout_then_reregisterable() {
    // Full lifecycle: register token → delete-all (logout cleanup) → register
    // the same token again after logout.  Verifies that delete-all doesn't
    // leave a dangling unique-constraint row that blocks re-registration.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "push_logout").await;

    let device_token = "device-token-logout-flow";

    // Register.
    let r1 = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": device_token, "platform": "apns" }))
        .send()
        .await
        .unwrap();
    assert_eq!(r1.status().as_u16(), 200);

    // Simulate logout -- bulk-delete all tokens.
    let del = client
        .delete(format!("{base}/api/push/token"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(del.status().as_u16(), 200, "logout cleanup must be 200");

    // Re-register (same token) after re-login should succeed.
    let r2 = client
        .post(format!("{base}/api/push/register"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "token": device_token, "platform": "apns" }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        r2.status().as_u16(),
        200,
        "re-register after logout must be 200"
    );
    let body: Value = r2.json().await.unwrap();
    assert_eq!(body["status"], "ok");
}
