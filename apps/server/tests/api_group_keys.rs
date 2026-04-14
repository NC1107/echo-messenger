//! Integration tests for group encryption key upload and retrieval.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Helper: create a group and return its id.
async fn create_group(client: &Client, base: &str, token: &str, name: &str) -> String {
    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        201,
        "create_group should return 201"
    );
    let body: Value = resp.json().await.unwrap();
    body["id"].as_str().unwrap().to_string()
}

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

#[tokio::test]
async fn upload_group_key_as_owner_returns_201() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkown").await;

    let group_id = create_group(&client, &base, &owner_token, "GKGroup").await;

    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "owner-envelope-aes-key" }
        ]
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["key_version"], 1);
}

#[tokio::test]
async fn upload_group_key_as_member_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _owner_id, _) = common::register_and_login(&client, &base, "gkmemown").await;
    let (member_token, member_id, _) = common::register_and_login(&client, &base, "gkmem").await;

    let group_id = create_group(&client, &base, &owner_token, "GKMemGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id).await;

    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": member_id, "encrypted_key": "attempt" }
        ]
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {member_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn upload_group_key_as_nonmember_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _owner_id, _) = common::register_and_login(&client, &base, "gknmown").await;
    let (stranger_token, stranger_id, _) = common::register_and_login(&client, &base, "gknm").await;

    let group_id = create_group(&client, &base, &owner_token, "GKNonMemGroup").await;

    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": stranger_id, "encrypted_key": "attempt" }
        ]
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn upload_group_key_empty_envelopes_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _owner_id, _) = common::register_and_login(&client, &base, "gkempty").await;

    let group_id = create_group(&client, &base, &owner_token, "GKEmptyEnv").await;

    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": []
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_group_key_zero_version_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkv0").await;

    let group_id = create_group(&client, &base, &owner_token, "GKZeroVer").await;

    let body = serde_json::json!({
        "key_version": 0,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "attempt" }
        ]
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_group_key_duplicate_version_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkdup").await;

    let group_id = create_group(&client, &base, &owner_token, "GKDupVer").await;

    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "first" }
        ]
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);

    // Same version again
    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "second" }
        ]
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 409);
}

// ---------------------------------------------------------------------------
// Retrieval
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_latest_returns_my_envelope() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gklown").await;
    let (member_token, member_id, _) = common::register_and_login(&client, &base, "gklmem").await;

    let group_id = create_group(&client, &base, &owner_token, "GKLatest").await;
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id).await;

    // Upload envelopes for both users
    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "owner-secret" },
            { "user_id": member_id, "encrypted_key": "member-secret" }
        ]
    });
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);

    // Owner fetches latest -- should see their own envelope
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["encrypted_key"], "owner-secret");
    assert_eq!(body["key_version"], 1);

    // Member fetches latest -- should see their own envelope
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["encrypted_key"], "member-secret");
}

#[tokio::test]
async fn get_version_returns_correct_envelope() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkvown").await;

    let group_id = create_group(&client, &base, &owner_token, "GKVersion").await;

    // Upload v1
    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "v1-key" }
        ]
    });
    client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();

    // Upload v2
    let body = serde_json::json!({
        "key_version": 2,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "v2-key" }
        ]
    });
    client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();

    // Fetch v1 specifically
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/1"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["encrypted_key"], "v1-key");
    assert_eq!(body["key_version"], 1);

    // Fetch v2 specifically
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/2"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["encrypted_key"], "v2-key");
    assert_eq!(body["key_version"], 2);
}
