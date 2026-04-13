//! Integration tests for block/unblock contact flows.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Helper: register a user, log in, return (token, user_id, username).
async fn setup(client: &Client, base: &str, prefix: &str) -> (String, String, String) {
    let username = common::unique_username(prefix);
    common::register(client, base, &username, "password123").await;
    let (token, user_id) = common::login(client, base, &username, "password123").await;
    (token, user_id, username)
}

// ---------------------------------------------------------------------------
// Block user
// ---------------------------------------------------------------------------

#[tokio::test]
async fn block_user_returns_201() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (alice_token, _, _) = setup(&client, &base, "blk_alice").await;
    let (_, bob_id, _) = setup(&client, &base, "blk_bob").await;

    let resp = client
        .post(format!("{base}/api/contacts/block"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "blocked");
}

#[tokio::test]
async fn blocked_user_appears_in_blocked_list() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (alice_token, _, _) = setup(&client, &base, "blklist_a").await;
    let (_, bob_id, _) = setup(&client, &base, "blklist_b").await;

    // Block Bob
    client
        .post(format!("{base}/api/contacts/block"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    // Alice lists blocked users
    let resp = client
        .get(format!("{base}/api/contacts/blocked"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let blocked: Vec<Value> = resp.json().await.unwrap();
    assert!(
        blocked
            .iter()
            .any(|u| u["blocked_id"].as_str() == Some(bob_id.as_str())),
        "Bob should appear in Alice's blocked list"
    );
}

#[tokio::test]
async fn cannot_block_self_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (alice_token, alice_id, _) = setup(&client, &base, "blkself").await;

    let resp = client
        .post(format!("{base}/api/contacts/block"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": alice_id }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Unblock user
// ---------------------------------------------------------------------------

#[tokio::test]
async fn unblock_user_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (alice_token, _, _) = setup(&client, &base, "ublk_alice").await;
    let (_, bob_id, _) = setup(&client, &base, "ublk_bob").await;

    // Block first
    client
        .post(format!("{base}/api/contacts/block"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    // Unblock
    let resp = client
        .post(format!("{base}/api/contacts/unblock"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "unblocked");
}

#[tokio::test]
async fn unblocked_user_no_longer_in_blocked_list() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (alice_token, _, _) = setup(&client, &base, "ublklist_a").await;
    let (_, bob_id, _) = setup(&client, &base, "ublklist_b").await;

    // Block then unblock
    client
        .post(format!("{base}/api/contacts/block"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    client
        .post(format!("{base}/api/contacts/unblock"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    let resp = client
        .get(format!("{base}/api/contacts/blocked"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    let blocked: Vec<Value> = resp.json().await.unwrap();
    assert!(
        !blocked
            .iter()
            .any(|u| u["blocked_id"].as_str() == Some(bob_id.as_str())),
        "Bob should no longer be in Alice's blocked list after unblock"
    );
}

#[tokio::test]
async fn unblock_not_blocked_user_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (alice_token, _, _) = setup(&client, &base, "ublknone_a").await;
    let (_, bob_id, _) = setup(&client, &base, "ublknone_b").await;

    let resp = client
        .post(format!("{base}/api/contacts/unblock"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Auth checks
// ---------------------------------------------------------------------------

#[tokio::test]
async fn block_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (_, bob_id, _) = setup(&client, &base, "blknoauth").await;

    let resp = client
        .post(format!("{base}/api/contacts/block"))
        .json(&serde_json::json!({ "user_id": bob_id }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}
