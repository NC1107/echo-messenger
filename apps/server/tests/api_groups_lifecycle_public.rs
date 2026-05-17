//! Integration tests for group lifecycle (leave / delete) and public-group
//! discovery (list / preview / join) endpoints.
//!
//! Covers leave_group, delete_group, list_public_groups, get_group_preview,
//! and join_group across happy-path, authorization, and not-found branches.

mod common;

use reqwest::Client;
use serde_json::Value;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Create a public group and return its id.
async fn create_public_group(client: &Client, base: &str, token: &str, name: &str) -> String {
    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name, "is_public": true }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        201,
        "create_public_group should 201"
    );
    let body: Value = resp.json().await.unwrap();
    body["id"].as_str().unwrap().to_string()
}

/// Ban a user from a group (owner / admin only).
async fn ban_user(client: &Client, base: &str, owner_token: &str, group_id: &str, user_id: &str) {
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/ban/{user_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "ban_user should 200");
}

/// Count messages matching a `__system__:<kind>:%` pattern for a group.
async fn count_system_messages(group_id: &str, kind: &str) -> i64 {
    let pool = common::test_pool().await;
    let pattern = format!("__system__:{kind}:%");
    let row: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM messages \
         WHERE conversation_id = $1 \
           AND content LIKE $2 \
           AND deleted_at IS NULL",
    )
    .bind(Uuid::parse_str(group_id).unwrap())
    .bind(&pattern)
    .fetch_one(&pool)
    .await
    .expect("system message count query failed");
    pool.close().await;
    row.0
}

/// Return `true` if the conversations row for `group_id` still exists.
async fn group_exists(group_id: &str) -> bool {
    let pool = common::test_pool().await;
    let row: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM conversations WHERE id = $1")
        .bind(Uuid::parse_str(group_id).unwrap())
        .fetch_optional(&pool)
        .await
        .unwrap();
    pool.close().await;
    row.is_some()
}

// ---------------------------------------------------------------------------
// leave_group
// ---------------------------------------------------------------------------

/// A regular member leaving emits a `member_left` system message.
#[tokio::test]
async fn leave_group_emits_system_message() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "lgsm_own").await;
    let (member_tok, member_id, _) = common::register_and_login(&client, &base, "lgsm_mem").await;

    let group_id = create_public_group(&client, &base, &owner_tok, "LeaveSysMsgGroup").await;
    common::add_member_to_group(&client, &base, &owner_tok, &group_id, &member_id).await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/leave"))
        .header("Authorization", format!("Bearer {member_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "left");

    let count = count_system_messages(&group_id, "member_left").await;
    assert_eq!(count, 1, "expected one member_left system message");
}

/// The sole owner (= last member) leaving auto-deletes the group.
#[tokio::test]
async fn leave_group_last_member_auto_deletes() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "lglast_own").await;
    let group_id = create_public_group(&client, &base, &owner_tok, "AutoDeleteGroup").await;

    // Owner is the only member; leaving should auto-delete the group.
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/leave"))
        .header("Authorization", format!("Bearer {owner_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "left");

    assert!(
        !group_exists(&group_id).await,
        "group should be auto-deleted when last member leaves"
    );
}

/// A user who is not a group member gets 401 when trying to leave.
#[tokio::test]
async fn leave_group_non_member_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "lgnm_own").await;
    let (stranger_tok, _, _) = common::register_and_login(&client, &base, "lgnm_str").await;

    let group_id = create_public_group(&client, &base, &owner_tok, "NonMemberLeaveGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/leave"))
        .header("Authorization", format!("Bearer {stranger_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401, "non-member leave should 401");
}

// ---------------------------------------------------------------------------
// delete_group
// ---------------------------------------------------------------------------

/// Group owner can delete the group; the conversation row is gone afterwards.
#[tokio::test]
async fn delete_group_owner_cascades() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "dgown_own").await;
    let group_id = common::create_group(&client, &base, &owner_tok, "DeleteCascadeGroup").await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {owner_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 204, "owner delete should 204");

    assert!(
        !group_exists(&group_id).await,
        "conversation row should be gone after delete"
    );
}

/// A non-owner member cannot delete the group; returns 401.
#[tokio::test]
async fn delete_group_non_owner_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "dgna_own").await;
    let (member_tok, member_id, _) = common::register_and_login(&client, &base, "dgna_mem").await;

    let group_id = common::create_group(&client, &base, &owner_tok, "NonOwnerDeleteGroup").await;
    common::add_member_to_group(&client, &base, &owner_tok, &group_id, &member_id).await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {member_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401, "non-owner delete should 401");
}

/// Deleting a non-existent group returns 401 (the owner-check fails → same code
/// as the non-owner path because the EXISTS subquery returns 0 rows).
#[tokio::test]
async fn delete_group_nonexistent_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (token, _, _) = common::register_and_login(&client, &base, "dgne_usr").await;
    let phantom_id = Uuid::new_v4();

    let resp = client
        .delete(format!("{base}/api/groups/{phantom_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        401,
        "non-existent group delete should 401"
    );
}

// ---------------------------------------------------------------------------
// list_public_groups
// ---------------------------------------------------------------------------

/// Private groups must not appear in the public listing.
#[tokio::test]
async fn list_public_groups_hides_private() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let tag = &Uuid::new_v4().simple().to_string()[..8];
    let (tok, _, _) = common::register_and_login(&client, &base, "lpg_usr").await;

    // One public, one private — both with the same unique tag in the name.
    let pub_name = format!("Pub_{tag}");
    let priv_name = format!("Priv_{tag}");
    create_public_group(&client, &base, &tok, &pub_name).await;
    common::create_group(&client, &base, &tok, &priv_name).await; // private by default

    let resp = client
        .get(format!("{base}/api/groups/public?search={tag}&limit=100"))
        .header("Authorization", format!("Bearer {tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let groups: Vec<Value> = resp.json().await.unwrap();

    assert!(
        groups
            .iter()
            .any(|g| g["title"].as_str() == Some(pub_name.as_str())),
        "public group should be visible"
    );
    assert!(
        !groups
            .iter()
            .any(|g| g["title"].as_str() == Some(priv_name.as_str())),
        "private group must not appear in public listing"
    );
}

/// Pagination: `limit=1` returns exactly one result; `offset=1` skips the first.
#[tokio::test]
async fn list_public_groups_pagination() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let tag = &Uuid::new_v4().simple().to_string()[..8];
    let (tok, _, _) = common::register_and_login(&client, &base, "lpg_pag").await;

    // Create two public groups so we have at least 2 rows in the tag namespace.
    create_public_group(&client, &base, &tok, &format!("PagA_{tag}")).await;
    create_public_group(&client, &base, &tok, &format!("PagB_{tag}")).await;

    // limit=1 should return exactly one group.
    let resp = client
        .get(format!("{base}/api/groups/public?search={tag}&limit=1"))
        .header("Authorization", format!("Bearer {tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let page1: Vec<Value> = resp.json().await.unwrap();
    assert_eq!(page1.len(), 1, "limit=1 should return exactly one group");

    // offset=1 should skip the first group.
    let resp = client
        .get(format!(
            "{base}/api/groups/public?search={tag}&limit=100&offset=1"
        ))
        .header("Authorization", format!("Bearer {tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let page2: Vec<Value> = resp.json().await.unwrap();
    assert_eq!(
        page2.len(),
        1,
        "offset=1 should skip the first and return only the second group"
    );

    // The two pages must not share the same group.
    assert_ne!(
        page1[0]["id"].as_str(),
        page2[0]["id"].as_str(),
        "pages should return different groups"
    );
}

/// Response items carry the expected fields and a valid `member_count`.
#[tokio::test]
async fn list_public_groups_response_shape() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let tag = &Uuid::new_v4().simple().to_string()[..8];
    let (tok, _, _) = common::register_and_login(&client, &base, "lpg_shp").await;
    let name = format!("Shape_{tag}");
    create_public_group(&client, &base, &tok, &name).await;

    let resp = client
        .get(format!("{base}/api/groups/public?search={tag}&limit=100"))
        .header("Authorization", format!("Bearer {tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let groups: Vec<Value> = resp.json().await.unwrap();
    let entry = groups
        .iter()
        .find(|g| g["title"].as_str() == Some(name.as_str()))
        .expect("newly created public group must appear in listing");

    assert!(entry["id"].as_str().is_some(), "id field must be present");
    assert!(
        entry["member_count"].as_i64().is_some(),
        "member_count field must be present"
    );
    assert!(
        entry["created_at"].as_str().is_some(),
        "created_at field must be present"
    );
    assert!(
        entry["is_member"].as_bool().is_some(),
        "is_member field must be present"
    );
    assert!(
        entry["member_count"].as_i64().unwrap() >= 1,
        "member_count should be at least 1 (creator)"
    );
}

// ---------------------------------------------------------------------------
// get_group_preview
// ---------------------------------------------------------------------------

/// A public group preview returns 200 with the expected fields.
#[tokio::test]
async fn get_group_preview_public_returns_200_with_shape() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "gpp_own").await;
    let (viewer_tok, _, _) = common::register_and_login(&client, &base, "gpp_view").await;

    let group_id = create_public_group(&client, &base, &owner_tok, "PreviewPublicGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/preview"))
        .header("Authorization", format!("Bearer {viewer_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();

    assert_eq!(
        body["id"].as_str(),
        Some(group_id.as_str()),
        "id must match"
    );
    assert!(body["title"].is_string(), "title must be present");
    assert!(
        body["member_count"].as_i64().is_some(),
        "member_count must be present"
    );
    assert_eq!(
        body["is_public"].as_bool(),
        Some(true),
        "is_public must be true"
    );
    assert!(body["members"].is_array(), "members must be an array");
    assert!(
        body["is_member"].as_bool().is_some(),
        "is_member flag must be present"
    );
}

/// Non-member requesting preview of a private group gets 404.
#[tokio::test]
async fn get_group_preview_private_non_member_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "gppri_own").await;
    let (stranger_tok, _, _) = common::register_and_login(&client, &base, "gppri_str").await;

    let group_id = common::create_group(&client, &base, &owner_tok, "PrivPreviewGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/preview"))
        .header("Authorization", format!("Bearer {stranger_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        404,
        "non-member preview of private group should 404"
    );
}

/// Preview of a completely non-existent group returns 404.
#[tokio::test]
async fn get_group_preview_nonexistent_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (tok, _, _) = common::register_and_login(&client, &base, "gppne_usr").await;
    let phantom_id = Uuid::new_v4();

    let resp = client
        .get(format!("{base}/api/groups/{phantom_id}/preview"))
        .header("Authorization", format!("Bearer {tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        404,
        "non-existent preview should 404"
    );
}

// ---------------------------------------------------------------------------
// join_group
// ---------------------------------------------------------------------------

/// Joining a public group succeeds and returns `{"status": "joined"}`.
#[tokio::test]
async fn join_public_group_happy_path() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "jg_own").await;
    let (joiner_tok, _, _) = common::register_and_login(&client, &base, "jg_join").await;

    let group_id = create_public_group(&client, &base, &owner_tok, "JoinHappyGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {joiner_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "joined");
}

/// Joining a group the caller is already a member of returns 409 (AlreadyMember).
#[tokio::test]
async fn join_group_already_member_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "jgam_own").await;
    let (joiner_tok, _, _) = common::register_and_login(&client, &base, "jgam_join").await;

    let group_id = create_public_group(&client, &base, &owner_tok, "AlreadyMemberGroup").await;

    // First join succeeds.
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {joiner_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "first join should succeed");

    // Second join is idempotent in the sense that the server rejects it (409).
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {joiner_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        409,
        "duplicate join should return 409"
    );
}

/// A banned user attempting to join a public group gets 400.
#[tokio::test]
async fn join_group_banned_user_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "jgban_own").await;
    let (banned_tok, banned_id, _) = common::register_and_login(&client, &base, "jgban_usr").await;

    let group_id = create_public_group(&client, &base, &owner_tok, "BannedJoinGroup").await;

    // Add then ban the user so the ban row exists without needing membership history.
    common::add_member_to_group(&client, &base, &owner_tok, &group_id, &banned_id).await;
    ban_user(&client, &base, &owner_tok, &group_id, &banned_id).await;

    // Banned user tries to rejoin.
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {banned_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "banned user join attempt should return 400"
    );
}

/// Trying to join a private group returns 400 ("not public").
#[tokio::test]
async fn join_private_group_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_tok, _, _) = common::register_and_login(&client, &base, "jgpriv_own").await;
    let (joiner_tok, _, _) = common::register_and_login(&client, &base, "jgpriv_join").await;

    let group_id = common::create_group(&client, &base, &owner_tok, "PrivateJoinTarget").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {joiner_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "joining a private group should return 400"
    );
}
