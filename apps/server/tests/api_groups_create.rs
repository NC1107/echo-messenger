//! Integration tests for `routes/groups/create.rs` and `routes/groups/types.rs`.
//!
//! Run with:
//! ```
//! TEST_DATABASE_URL='postgres://echo:test_password@localhost:5433/echo_test' \
//!   cargo test -p echo-server --test api_groups_create
//! ```

mod common;

use reqwest::Client;
use serde_json::Value;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// create_group — happy path
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_happy_path_returns_201_with_group_id() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "cgcreate").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "HappyGroup" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["id"].as_str().is_some(),
        "response must include a group id"
    );
    // kind should be present and non-empty
    assert!(
        body["kind"].as_str().is_some(),
        "response must include kind field"
    );
}

// ---------------------------------------------------------------------------
// create_group — creator becomes member with 'owner' role
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_creator_is_member_with_owner_role() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, user_id, _) = common::register_and_login(&client, &base, "cgowner").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "OwnerBootstrapGroup" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();

    let members = body["members"]
        .as_array()
        .expect("members must be an array");
    assert!(!members.is_empty(), "members list must not be empty");

    let creator = members
        .iter()
        .find(|m| m["user_id"].as_str() == Some(&user_id));
    assert!(creator.is_some(), "creator must appear in the members list");
    assert_eq!(
        creator.unwrap()["role"].as_str(),
        Some("owner"),
        "creator role must be 'owner'"
    );
}

// ---------------------------------------------------------------------------
// create_group — member_ids bootstrap: additional members appear in response
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_with_member_ids_bootstraps_members() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "cgbootown").await;
    let (_, member_id, _) = common::register_and_login(&client, &base, "cgbootmem").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({
            "name": "BootstrapGroup",
            "member_ids": [member_id]
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();

    let members = body["members"]
        .as_array()
        .expect("members must be an array");
    let ids: Vec<&str> = members
        .iter()
        .filter_map(|m| m["user_id"].as_str())
        .collect();
    assert!(
        ids.contains(&owner_id.as_str()),
        "owner must be in bootstrapped members"
    );
    assert!(
        ids.contains(&member_id.as_str()),
        "seeded member_id must appear in bootstrapped members"
    );
}

// ---------------------------------------------------------------------------
// create_group — unauthorized (missing token) → 401
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_missing_token_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/groups"))
        .json(&serde_json::json!({ "name": "ShouldFail" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// create_group — empty name → 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_empty_name_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "cgempty").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// create_group — name too long (> 100 chars) → 400
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_name_too_long_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "cglong").await;

    let long_name = "a".repeat(101);

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": long_name }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// create_group — 100-char name is the boundary: should succeed
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_name_at_100_chars_is_accepted() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "cgboundary").await;

    let exact_name = "a".repeat(100);

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": exact_name }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
}

// ---------------------------------------------------------------------------
// create_group — duplicate public group name by same creator → 409
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_duplicate_public_name_by_same_user_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "cgdupname").await;

    let name = format!("DupPub_{}", &Uuid::new_v4().simple().to_string()[..6]);

    // First creation should succeed.
    let first = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name, "is_public": true }))
        .send()
        .await
        .unwrap();
    assert_eq!(first.status().as_u16(), 201, "first creation must succeed");

    // Second creation with the same public name should conflict.
    let second = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name, "is_public": true }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        second.status().as_u16(),
        409,
        "duplicate public name by same user must return 409"
    );
}

// ---------------------------------------------------------------------------
// create_group — duplicate private group name by same creator is allowed
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_duplicate_private_name_is_allowed() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "cgduppriv").await;

    let name = format!("DupPriv_{}", &Uuid::new_v4().simple().to_string()[..6]);

    let first = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name, "is_public": false }))
        .send()
        .await
        .unwrap();
    assert_eq!(first.status().as_u16(), 201);

    // Private groups have no uniqueness constraint per creator.
    let second = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name, "is_public": false }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        second.status().as_u16(),
        201,
        "duplicate private name by same user is permitted"
    );
}

// ---------------------------------------------------------------------------
// create_group — default channels are seeded on creation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_seeds_default_channels() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "cgchannels").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "ChannelSeedGroup" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let group_id = body["id"].as_str().unwrap();

    // Verify via the channels endpoint that general + lounge exist.
    let ch_resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(ch_resp.status().as_u16(), 200);
    let channels: Vec<Value> = ch_resp.json().await.unwrap();
    let names: Vec<&str> = channels.iter().filter_map(|c| c["name"].as_str()).collect();
    assert!(
        names.contains(&"general"),
        "general text channel must be seeded; got: {names:?}"
    );
    assert!(
        names.contains(&"lounge"),
        "lounge voice channel must be seeded; got: {names:?}"
    );
}

// ---------------------------------------------------------------------------
// get_group — happy path: member can fetch group info
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_group_member_can_fetch() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "ggfetch").await;

    let group_id = common::create_group(&client, &base, &token, "FetchableGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(
        body["id"].as_str(),
        Some(group_id.as_str()),
        "returned id must match"
    );
    assert!(
        body["kind"].as_str().is_some(),
        "kind field must be present"
    );
    assert!(
        body["members"].as_array().is_some(),
        "members array must be present"
    );
}

// ---------------------------------------------------------------------------
// get_group — non-member receives 401 (NotMember error code)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_group_non_member_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "ggnmown").await;
    let (stranger_token, _, _) = common::register_and_login(&client, &base, "ggnmstr").await;

    let group_id = common::create_group(&client, &base, &owner_token, "NonMemberGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(
        body["code"].as_str(),
        Some("not-member"),
        "error code must be 'not-member'"
    );
}

// ---------------------------------------------------------------------------
// get_group — non-existent UUID: is_member returns false → 401
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_group_nonexistent_uuid_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "ggnoexist").await;

    let random_id = Uuid::new_v4();

    let resp = client
        .get(format!("{base}/api/groups/{random_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    // The handler checks is_member first; a non-existent group ID returns false
    // from is_member → 401 NotMember before even attempting to fetch the group.
    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// get_group — missing auth → 401
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_group_missing_token_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "ggnoauth").await;

    let group_id = common::create_group(&client, &base, &token, "AuthRequiredGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}
