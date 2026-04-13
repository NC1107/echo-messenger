//! Integration tests for group management endpoints.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Helper: register a user, log in, and return (token, user_id).
async fn register_and_login(client: &Client, base: &str, prefix: &str) -> (String, String) {
    let username = common::unique_username(prefix);
    common::register(client, base, &username, "password123").await;
    common::login(client, base, &username, "password123").await
}

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
// Group creation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_group_returns_201_with_owner() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, user_id) = register_and_login(&client, &base, "grpcreate").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "TestGroup" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert!(body["id"].as_str().is_some(), "should have group id");

    // Creator should be in the members list as owner
    let members = body["members"].as_array().unwrap();
    let creator = members
        .iter()
        .find(|m| m["user_id"].as_str() == Some(&user_id));
    assert!(creator.is_some(), "creator should be in members list");
    assert_eq!(creator.unwrap()["role"], "owner");
}

#[tokio::test]
async fn create_group_empty_name_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "grpempty").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": "" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn create_group_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/groups"))
        .json(&serde_json::json!({ "name": "Unauthorized" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Get group
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_group_returns_group_info() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "grpget").await;

    let group_id = create_group(&client, &base, &token, "GetMeGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["id"].as_str(), Some(group_id.as_str()));
}

#[tokio::test]
async fn get_group_non_member_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token_owner, _) = register_and_login(&client, &base, "grpowner").await;
    let (token_stranger, _) = register_and_login(&client, &base, "grpstranger").await;

    let group_id = create_group(&client, &base, &token_owner, "PrivateGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token_stranger}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Member management
// ---------------------------------------------------------------------------

#[tokio::test]
async fn add_and_remove_member() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "grpown").await;
    let (_, new_member_id) = register_and_login(&client, &base, "grpmem").await;

    let group_id = create_group(&client, &base, &owner_token, "MemberGroup").await;

    // Add member
    let add_resp = client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": new_member_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(add_resp.status().as_u16(), 200);
    let add_body: Value = add_resp.json().await.unwrap();
    assert_eq!(add_body["status"], "added");

    // Remove member
    let remove_resp = client
        .delete(format!(
            "{base}/api/groups/{group_id}/members/{new_member_id}"
        ))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(remove_resp.status().as_u16(), 200);
    let remove_body: Value = remove_resp.json().await.unwrap();
    assert_eq!(remove_body["status"], "removed");
}

#[tokio::test]
async fn add_member_already_member_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id) = register_and_login(&client, &base, "grpdup").await;

    let group_id = create_group(&client, &base, &owner_token, "DupMemberGroup").await;

    // Try to add the owner again (already a member)
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": owner_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 409);
}

#[tokio::test]
async fn regular_member_cannot_add_to_private_group() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "grpprivowner").await;
    let (member_token, member_id) = register_and_login(&client, &base, "grpprivmem").await;
    let (_, outsider_id) = register_and_login(&client, &base, "grpprivout").await;

    let group_id = create_group(&client, &base, &owner_token, "PrivAddGroup").await;

    // Add member via owner
    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    // Member tries to add outsider — should be rejected (private group)
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {member_token}"))
        .json(&serde_json::json!({ "user_id": outsider_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Public groups
// ---------------------------------------------------------------------------

#[tokio::test]
async fn public_group_appears_in_list() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "pubgrp").await;

    let unique_name = format!(
        "PublicGroup_{}",
        &uuid::Uuid::new_v4().simple().to_string()[..6]
    );

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": unique_name, "is_public": true }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);

    let list_resp = client
        .get(format!("{base}/api/groups/public"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(list_resp.status().as_u16(), 200);
    let groups: Vec<Value> = list_resp.json().await.unwrap();
    assert!(
        groups
            .iter()
            .any(|g| g["title"].as_str() == Some(&unique_name)),
        "public group should appear in list"
    );
}

#[tokio::test]
async fn join_public_group_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "joinowner").await;
    let (joiner_token, _) = register_and_login(&client, &base, "joiner").await;

    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "name": "JoinableGroup", "is_public": true }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let group_id = body["id"].as_str().unwrap().to_string();

    let join_resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(join_resp.status().as_u16(), 200);
    let join_body: Value = join_resp.json().await.unwrap();
    assert_eq!(join_body["status"], "joined");
}

#[tokio::test]
async fn join_private_group_fails() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "privjoinown").await;
    let (joiner_token, _) = register_and_login(&client, &base, "privjoiner").await;

    let group_id = create_group(&client, &base, &owner_token, "PrivateJoinGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Leave group
// ---------------------------------------------------------------------------

#[tokio::test]
async fn member_can_leave_group() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "leaveown").await;
    let (member_token, member_id) = register_and_login(&client, &base, "leavemem").await;

    let group_id = create_group(&client, &base, &owner_token, "LeaveGroup").await;

    // Add member
    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    // Member leaves
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/leave"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "left");
}

#[tokio::test]
async fn owner_cannot_leave_group_with_other_members() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "ownleave").await;
    let (_, member_id) = register_and_login(&client, &base, "ownleavemem").await;

    let group_id = create_group(&client, &base, &owner_token, "OwnerLeaveGroup").await;

    // Add a member so the group has >1 members
    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    // Owner tries to leave — should be rejected
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/leave"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("Transfer ownership")
    );
}

// ---------------------------------------------------------------------------
// Update group
// ---------------------------------------------------------------------------

#[tokio::test]
async fn owner_can_update_group_title() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "grpupd").await;

    let group_id = create_group(&client, &base, &token, "OriginalName").await;

    let resp = client
        .put(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "title": "UpdatedName" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "updated");

    // Verify the title was actually stored by fetching the group
    let get_resp = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(get_resp.status().as_u16(), 200);
    let get_body: Value = get_resp.json().await.unwrap();
    assert_eq!(get_body["title"], "UpdatedName");
}

// ---------------------------------------------------------------------------
// Delete group
// ---------------------------------------------------------------------------

#[tokio::test]
async fn owner_can_delete_group() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "grpdel").await;

    let group_id = create_group(&client, &base, &token, "DeleteMeGroup").await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 204);
}

#[tokio::test]
async fn non_owner_cannot_delete_group() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "delnown").await;
    let (member_token, member_id) = register_and_login(&client, &base, "delnmem").await;

    let group_id = create_group(&client, &base, &owner_token, "CantDeleteGroup").await;

    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}
