//! Integration tests for group invite link endpoints (#579).

mod common;

use reqwest::Client;
use serde_json::Value;

/// Helper: register + login, return (token, user_id).
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
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    body["id"].as_str().unwrap().to_string()
}

/// Helper: create an invite for a group, return (token_str, url).
async fn create_invite(
    client: &Client,
    base: &str,
    auth_token: &str,
    group_id: &str,
) -> (String, String) {
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {auth_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        201,
        "create_invite should return 201"
    );
    let body: Value = resp.json().await.unwrap();
    let tok = body["token"].as_str().unwrap().to_string();
    let url = body["url"].as_str().unwrap().to_string();
    (tok, url)
}

// ---------------------------------------------------------------------------
// Create invite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_invite_returns_201_with_token_and_url() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "invcreat").await;
    let group_id = create_group(&client, &base, &token, "InvCreateGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert!(body["token"].as_str().is_some(), "should have token");
    assert!(body["url"].as_str().is_some(), "should have url");
    assert!(
        body["url"]
            .as_str()
            .unwrap()
            .contains(body["token"].as_str().unwrap()),
        "url should contain token"
    );
}

#[tokio::test]
async fn non_member_cannot_create_invite() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "invcrnomem_own").await;
    let (other_token, _) = register_and_login(&client, &base, "invcrnomem_oth").await;
    let group_id = create_group(&client, &base, &owner_token, "InvNoMemGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {other_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 403);
}

#[tokio::test]
async fn regular_member_cannot_create_invite() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "invmemcr_own").await;
    let (member_token, member_id) = register_and_login(&client, &base, "invmemcr_mem").await;
    let group_id = create_group(&client, &base, &owner_token, "InvMembGroup").await;

    // Add the member to the group
    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 403);
}

// ---------------------------------------------------------------------------
// Preview invite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn preview_invite_returns_group_info() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "invprev").await;
    let group_id = create_group(&client, &base, &token, "InvPrevGroup").await;
    let (inv_token, _) = create_invite(&client, &base, &token, &group_id).await;

    let resp = client
        .get(format!("{base}/api/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["token"].as_str().unwrap(), inv_token);
    assert!(body["group"]["id"].as_str().is_some());
    assert_eq!(body["group"]["title"].as_str().unwrap(), "InvPrevGroup");
}

#[tokio::test]
async fn preview_invalid_token_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "invprev404").await;

    let resp = client
        .get(format!("{base}/api/invites/nosuchtoken"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 404);
}

// ---------------------------------------------------------------------------
// Accept invite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn accept_invite_joins_group() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "invaccept_own").await;
    let (joiner_token, joiner_id) = register_and_login(&client, &base, "invaccept_joi").await;
    let group_id = create_group(&client, &base, &owner_token, "InvAccGroup").await;
    let (inv_token, _) = create_invite(&client, &base, &owner_token, &group_id).await;

    let resp = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"].as_str().unwrap(), "joined");

    // Verify membership via group info
    let grp_resp = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(grp_resp.status().as_u16(), 200);
    let grp_body: Value = grp_resp.json().await.unwrap();
    let members = grp_body["members"].as_array().unwrap();
    assert!(
        members
            .iter()
            .any(|m| m["user_id"].as_str() == Some(&joiner_id)),
        "joiner should be in group members"
    );
}

#[tokio::test]
async fn accept_invite_increments_use_count() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "invuse_own").await;
    let (joiner_token, _) = register_and_login(&client, &base, "invuse_joi").await;
    let group_id = create_group(&client, &base, &owner_token, "InvUseGroup").await;
    let (inv_token, _) = create_invite(&client, &base, &owner_token, &group_id).await;

    // Accept
    client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();

    // Owner lists invites and checks use_count
    let list_resp = client
        .get(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(list_resp.status().as_u16(), 200);
    let list: Vec<Value> = list_resp.json().await.unwrap();
    let inv = list.iter().find(|t| t["token"] == inv_token).unwrap();
    assert_eq!(inv["use_count"].as_i64().unwrap(), 1);
}

#[tokio::test]
async fn accept_invalid_invite_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "invaccept404").await;

    let resp = client
        .post(format!("{base}/api/invites/nosuchtoken123/accept"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 404);
}

// ---------------------------------------------------------------------------
// Max-uses exhaustion
// ---------------------------------------------------------------------------

#[tokio::test]
async fn max_uses_exhausted_rejects_accept() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "invmax_own").await;
    let (j1_token, _) = register_and_login(&client, &base, "invmax_j1").await;
    let (j2_token, _) = register_and_login(&client, &base, "invmax_j2").await;
    let group_id = create_group(&client, &base, &owner_token, "InvMaxGroup").await;

    // Create invite limited to 1 use
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "max_uses": 1 }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let inv_token = body["token"].as_str().unwrap().to_string();

    // First joiner succeeds
    let r1 = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {j1_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(r1.status().as_u16(), 200);

    // Second joiner is rejected (use limit reached)
    let r2 = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {j2_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(r2.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Revoke invite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn revoke_invite_returns_204() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "invrevoke").await;
    let group_id = create_group(&client, &base, &token, "InvRevokeGroup").await;
    let (inv_token, _) = create_invite(&client, &base, &token, &group_id).await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 204);
}

#[tokio::test]
async fn revoked_invite_rejected_on_accept() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "invrev_own").await;
    let (joiner_token, _) = register_and_login(&client, &base, "invrev_joi").await;
    let group_id = create_group(&client, &base, &owner_token, "InvRevGroup").await;
    let (inv_token, _) = create_invite(&client, &base, &owner_token, &group_id).await;

    // Revoke
    client
        .delete(format!("{base}/api/groups/{group_id}/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();

    // Joiner tries to accept — should get 404
    let resp = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn revoke_nonexistent_invite_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "invrevokenil").await;
    let group_id = create_group(&client, &base, &token, "InvRevNilGroup").await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/invites/nonexistent"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 404);
}

// ---------------------------------------------------------------------------
// Banned user
// ---------------------------------------------------------------------------

#[tokio::test]
async fn banned_user_cannot_accept_invite() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "invban_own").await;
    let (banned_token, banned_id) = register_and_login(&client, &base, "invban_ban").await;
    let group_id = create_group(&client, &base, &owner_token, "InvBanGroup").await;

    // Add then ban the user
    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": banned_id }))
        .send()
        .await
        .unwrap();
    client
        .post(format!("{base}/api/groups/{group_id}/ban/{banned_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();

    let (inv_token, _) = create_invite(&client, &base, &owner_token, &group_id).await;

    let resp = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {banned_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// TOCTOU concurrency (#829)
// ---------------------------------------------------------------------------

/// Concurrent accepts against a `max_uses=1` token must not be allowed to
/// over-consume the token: only one accept may add a member. Pre-#829, the
/// pre-tx validation in the route handler was checked OUTSIDE the
/// FOR UPDATE lock on the token row, so a burst of N concurrent requests
/// could each pass validation and then each insert a member.
#[tokio::test]
async fn concurrent_accept_respects_max_uses_under_lock() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_token, _) = register_and_login(&client, &base, "invtoc_own").await;
    let group_id = create_group(&client, &base, &owner_token, "InvToctouGroup").await;

    // Create a single-use invite.
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "max_uses": 1 }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let inv_token = body["token"].as_str().unwrap().to_string();

    // Register 2 prospective joiners and collect their tokens. 2 is enough
    // contention to deterministically exercise the TOCTOU race without
    // blowing the per-IP register rate limit (3/60s, shared with the
    // owner registration above).
    let mut joiner_tokens = Vec::with_capacity(2);
    for i in 0..2 {
        let (tok, _) = register_and_login(&client, &base, &format!("invtoc_j{i}")).await;
        joiner_tokens.push(tok);
    }

    // Fire all accept requests concurrently.
    let base_arc = std::sync::Arc::new(base);
    let url_path = format!("/api/invites/{inv_token}/accept");
    let mut handles = Vec::with_capacity(joiner_tokens.len());
    for joiner_token in joiner_tokens {
        let base_clone = base_arc.clone();
        let url_path_clone = url_path.clone();
        let c = client.clone();
        handles.push(tokio::spawn(async move {
            c.post(format!("{base_clone}{url_path_clone}"))
                .header("Authorization", format!("Bearer {joiner_token}"))
                .send()
                .await
                .map(|r| r.status().as_u16())
        }));
    }

    let mut successes = 0;
    let mut rejections = 0;
    for h in handles {
        match h.await.unwrap() {
            Ok(200) => successes += 1,
            Ok(400) | Ok(404) => rejections += 1,
            Ok(other) => panic!("unexpected status {other}"),
            Err(e) => panic!("request error: {e}"),
        }
    }

    assert_eq!(
        successes, 1,
        "exactly one concurrent accept must succeed for a max_uses=1 token"
    );
    assert_eq!(
        rejections, 1,
        "the losing concurrent accept must be rejected"
    );

    // Verify use_count is exactly 1 in the listing.
    let list_resp = client
        .get(format!("{}/api/groups/{group_id}/invites", *base_arc))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    let invites: Value = list_resp.json().await.unwrap();
    let inv = invites
        .as_array()
        .expect("invites response is an array")
        .iter()
        .find(|i| i["token"].as_str() == Some(inv_token.as_str()))
        .expect("invite still listed");
    assert_eq!(
        inv["use_count"].as_i64().unwrap(),
        1,
        "use_count must not exceed max_uses under concurrent load"
    );
}
