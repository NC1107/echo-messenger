//! Integration tests for group encryption key upload and retrieval.

mod common;

use reqwest::Client;
use serde_json::Value;

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

#[tokio::test]
async fn upload_group_key_as_owner_returns_201() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkown").await;

    let group_id = common::create_group(&client, &base, &owner_token, "GKGroup").await;

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

    let group_id = common::create_group(&client, &base, &owner_token, "GKMemGroup").await;
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

    let group_id = common::create_group(&client, &base, &owner_token, "GKNonMemGroup").await;

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

    let group_id = common::create_group(&client, &base, &owner_token, "GKEmptyEnv").await;

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

    let group_id = common::create_group(&client, &base, &owner_token, "GKZeroVer").await;

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

    let group_id = common::create_group(&client, &base, &owner_token, "GKDupVer").await;

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

    let group_id = common::create_group(&client, &base, &owner_token, "GKLatest").await;
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

    let group_id = common::create_group(&client, &base, &owner_token, "GKVersion").await;

    // Upload v1
    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "v1-key" }
        ]
    });
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "upload v1 failed");

    // Upload v2
    let body = serde_json::json!({
        "key_version": 2,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "v2-key" }
        ]
    });
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "upload v2 failed");

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

// ---------------------------------------------------------------------------
// #686 + #687: non-member recipient rejected; no partial state written
// ---------------------------------------------------------------------------

/// An admin uploading envelopes that include a non-member user_id must get 400
/// and no envelope rows must be written (transactional rollback, #687).
#[tokio::test]
async fn upload_group_key_non_member_recipient_rejected_and_no_partial_state() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gknrpown").await;
    // Stranger is a real user but never added to the group.
    let (_stranger_token, stranger_id, _) =
        common::register_and_login(&client, &base, "gknrpstr").await;

    let group_id = common::create_group(&client, &base, &owner_token, "GKNonRecip").await;

    // Envelope list: one valid (owner) + one invalid (stranger non-member).
    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id,   "encrypted_key": "owner-envelope" },
            { "user_id": stranger_id, "encrypted_key": "stranger-envelope" }
        ]
    });

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();

    // Must be rejected (400) -- #686
    assert_eq!(
        resp.status().as_u16(),
        400,
        "non-member envelope must return 400"
    );

    // Verify no envelope was persisted for the owner either -- full rollback (#687).
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    // 400 == no key exists for this group at all (upload rolled back entirely)
    assert_eq!(
        resp.status().as_u16(),
        400,
        "no envelope row should have been committed (transaction must have rolled back)"
    );
}

// ---------------------------------------------------------------------------
// min_wire_version (Phase 2A — GRP1→GRP2 downgrade-attack mitigation)
// ---------------------------------------------------------------------------
//
// These tests cover the schema + API contract introduced by migration
// 20260518000000. Receiver-side enforcement (refusing GRP1 wires against
// a min_wire_version=2 envelope) lives in the client and is tested
// separately in apps/client/test/.

#[tokio::test]
async fn upload_group_key_without_min_wire_version_defaults_to_1() {
    // Existing clients (pre-Phase-2) don't send min_wire_version. The
    // server must accept their payload and default to 1 so backwards
    // compatibility holds.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkmwvdef").await;
    let group_id = common::create_group(&client, &base, &owner_token, "GKMWVDef").await;

    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "envelope-v1" }
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

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(
        body["min_wire_version"], 1,
        "omitted min_wire_version must default to 1"
    );
}

#[tokio::test]
async fn upload_group_key_with_min_wire_version_2_round_trips() {
    // A GRP2-capable rotator pins min_wire_version=2 to lock receivers
    // out of the legacy GRP1 wire format. The server stores it; the GET
    // endpoint surfaces it.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkmwv2").await;
    let group_id = common::create_group(&client, &base, &owner_token, "GKMWV2").await;

    let body = serde_json::json!({
        "key_version": 1,
        "min_wire_version": 2,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "envelope-v2" }
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

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["min_wire_version"], 2);
    assert_eq!(body["encrypted_key"], "envelope-v2");
}

#[tokio::test]
async fn upload_group_key_with_invalid_min_wire_version_returns_400() {
    // Out-of-range values are rejected with a typed 400 before they hit
    // the CHECK constraint, so clients get a clear error rather than a
    // database 23514.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gkmwvbad").await;
    let group_id = common::create_group(&client, &base, &owner_token, "GKMWVBad").await;

    for bad in [0i32, -1, 256, 9999] {
        let body = serde_json::json!({
            "key_version": 1,
            "min_wire_version": bad,
            "envelopes": [
                { "user_id": owner_id, "encrypted_key": "x" }
            ]
        });
        let resp = client
            .post(format!("{base}/api/groups/{group_id}/keys"))
            .header("Authorization", format!("Bearer {owner_token}"))
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(
            resp.status().as_u16(),
            400,
            "min_wire_version={bad} must be rejected with 400"
        );
    }
}
