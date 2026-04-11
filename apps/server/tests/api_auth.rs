//! Integration tests for authentication endpoints.

mod common;

use reqwest::Client;

#[tokio::test]
async fn register_returns_201() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("reg201");

    let resp = common::register_raw(&client, &base, &username, "password123").await;
    assert_eq!(resp.status().as_u16(), 201);
}

#[tokio::test]
async fn register_duplicate_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("regdup");

    let first = common::register_raw(&client, &base, &username, "password123").await;
    assert_eq!(first.status().as_u16(), 201);

    let second = common::register_raw(&client, &base, &username, "password123").await;
    assert_eq!(second.status().as_u16(), 409);
}

#[tokio::test]
async fn login_returns_tokens() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("logintok");

    common::register(&client, &base, &username, "password123").await;

    let resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(resp.status().as_u16(), 200);

    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());
    assert!(body["user_id"].as_str().is_some());
}

#[tokio::test]
async fn login_wrong_password_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("loginbad");

    common::register(&client, &base, &username, "password123").await;

    let resp = common::login_raw(&client, &base, &username, "wrong_password").await;
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn protected_route_without_token_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/contacts"))
        .send()
        .await
        .expect("request failed");

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn refresh_token_returns_new_tokens() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("refresh");

    common::register(&client, &base, &username, "password123").await;
    let login_body: serde_json::Value = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({ "username": username, "password": "password123" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let refresh_token = login_body["refresh_token"].as_str().unwrap();

    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());
}

#[tokio::test]
async fn refresh_token_revoked_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("revoked");

    common::register(&client, &base, &username, "password123").await;
    let login_body: serde_json::Value = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({ "username": username, "password": "password123" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let refresh_token = login_body["refresh_token"].as_str().unwrap();

    // First refresh — consumes (revokes) the original token
    let resp1 = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp1.status().as_u16(), 200);

    // Replay the SAME old token — should fail (theft detection)
    let resp2 = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp2.status().as_u16(),
        401,
        "replaying a revoked refresh token should return 401"
    );
}
