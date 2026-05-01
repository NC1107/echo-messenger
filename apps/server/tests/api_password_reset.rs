//! Integration tests for forgot-password / reset-password flow (#476).

mod common;

use reqwest::Client;

// ---------------------------------------------------------------------------
// POST /api/auth/forgot-password
// ---------------------------------------------------------------------------

/// Unknown username must still return 200 (no enumeration).
#[tokio::test]
async fn forgot_password_unknown_user_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/auth/forgot-password"))
        .json(&serde_json::json!({ "username": "does_not_exist_xyz987" }))
        .send()
        .await
        .expect("request failed");

    assert_eq!(resp.status().as_u16(), 200);
}

/// Known username also returns 200 (same status either way).
#[tokio::test]
async fn forgot_password_known_user_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("fpknown");

    common::register(&client, &base, &username, "password123").await;

    let resp = client
        .post(format!("{base}/api/auth/forgot-password"))
        .json(&serde_json::json!({ "username": username }))
        .send()
        .await
        .expect("request failed");

    assert_eq!(resp.status().as_u16(), 200);
}

// ---------------------------------------------------------------------------
// POST /api/auth/reset-password
// ---------------------------------------------------------------------------

/// Helper: register a user, request a reset token from the DB, and return
/// (base_url, token, username).
async fn setup_reset(client: &Client, base: &str, suffix: &str) -> (String, String) {
    let username = common::unique_username(suffix);
    common::register(client, base, &username, "old_password123").await;

    // Trigger forgot-password so the token row is created.
    client
        .post(format!("{base}/api/auth/forgot-password"))
        .json(&serde_json::json!({ "username": username }))
        .send()
        .await
        .expect("forgot-password request failed");

    // Fetch the raw token directly from the DB.
    let pool = common::test_pool().await;
    let row: (String,) = sqlx::query_as(
        "SELECT token FROM password_reset_tokens \
         WHERE user_id = (SELECT id FROM users WHERE username = $1) \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(&username)
    .fetch_one(&pool)
    .await
    .expect("token not found in DB");

    (username, row.0)
}

#[tokio::test]
async fn reset_password_happy_path() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (_username, token) = setup_reset(&client, &base, "rpok").await;

    let resp = client
        .post(format!("{base}/api/auth/reset-password"))
        .json(&serde_json::json!({
            "token": token,
            "new_password": "new_secure_password_456",
        }))
        .send()
        .await
        .expect("request failed");

    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn reset_password_new_password_works_for_login() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (username, token) = setup_reset(&client, &base, "rplogin").await;

    // Reset the password.
    client
        .post(format!("{base}/api/auth/reset-password"))
        .json(&serde_json::json!({
            "token": token,
            "new_password": "new_secure_password_789",
        }))
        .send()
        .await
        .expect("reset request failed");

    // Old password must be rejected.
    let old_resp = common::login_raw(&client, &base, &username, "old_password123").await;
    assert_eq!(old_resp.status().as_u16(), 401);

    // New password must work.
    let new_resp = common::login_raw(&client, &base, &username, "new_secure_password_789").await;
    assert_eq!(new_resp.status().as_u16(), 200);
}

#[tokio::test]
async fn reset_password_token_reuse_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (_username, token) = setup_reset(&client, &base, "rpreuse").await;

    // First use succeeds.
    let first = client
        .post(format!("{base}/api/auth/reset-password"))
        .json(&serde_json::json!({
            "token": token,
            "new_password": "new_secure_pw_first111",
        }))
        .send()
        .await
        .expect("first reset failed");
    assert_eq!(first.status().as_u16(), 200);

    // Second use with the same token must be rejected.
    let second = client
        .post(format!("{base}/api/auth/reset-password"))
        .json(&serde_json::json!({
            "token": token,
            "new_password": "new_secure_pw_second222",
        }))
        .send()
        .await
        .expect("second reset failed");
    assert_eq!(second.status().as_u16(), 400);
}

#[tokio::test]
async fn reset_password_invalid_token_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/auth/reset-password"))
        .json(&serde_json::json!({
            "token": "0000000000000000000000000000000000000000000000000000000000000000",
            "new_password": "new_secure_password_000",
        }))
        .send()
        .await
        .expect("request failed");

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn reset_password_short_password_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (_username, token) = setup_reset(&client, &base, "rpshort").await;

    let resp = client
        .post(format!("{base}/api/auth/reset-password"))
        .json(&serde_json::json!({
            "token": token,
            "new_password": "short",
        }))
        .send()
        .await
        .expect("request failed");

    assert_eq!(resp.status().as_u16(), 400);
}
