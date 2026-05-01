//! Integration tests for the denormalized member_count on conversations (#640).
//!
//! Verifies that:
//! - `list_public_groups` returns groups ordered by `member_count DESC`.
//! - The `is_member` flag is set correctly via the LEFT JOIN path.
//! - Adding and removing members keeps `member_count` consistent.

mod common;

use reqwest::Client;
use serde_json::Value;

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
        "create public group should 201"
    );
    let body: Value = resp.json().await.unwrap();
    body["id"].as_str().unwrap().to_string()
}

async fn join_group(client: &Client, base: &str, token: &str, group_id: &str) {
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/join"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "join group should 200");
}

async fn leave_group(client: &Client, base: &str, token: &str, group_id: &str) {
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/leave"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "leave group should 200");
}

/// List public groups filtered by a search term (avoids pagination issues with a shared DB).
async fn search_public_groups(
    client: &Client,
    base: &str,
    token: &str,
    search: &str,
) -> Vec<Value> {
    let resp = client
        .get(format!(
            "{base}/api/groups/public?search={search}&limit=100"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "list public groups should 200");
    resp.json::<Value>()
        .await
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

/// Verify that `list_public_groups` orders by `member_count DESC` and that the
/// `is_member` flag reflects actual membership via the LEFT JOIN path.
#[tokio::test]
async fn member_count_ordering_and_is_member_flag() {
    let base = common::spawn_server().await;
    let client = Client::new();

    // Each test uses a unique tag so searches don't cross-contaminate.
    let tag = &uuid::Uuid::new_v4().simple().to_string()[..8];
    let big_name = format!("BigGroup_{tag}");
    let small_name = format!("SmallGroup_{tag}");

    // Owner creates two public groups; only one of them gets extra members.
    let (owner_tok, _owner_id, _) = common::register_and_login(&client, &base, "mc_owner").await;
    let (user_b_tok, user_b_id, _) = common::register_and_login(&client, &base, "mc_userb").await;
    let (user_c_tok, user_c_id, _) = common::register_and_login(&client, &base, "mc_userc").await;

    let grp_big = create_public_group(&client, &base, &owner_tok, &big_name).await;
    let grp_small = create_public_group(&client, &base, &owner_tok, &small_name).await;

    // Add two extra members to grp_big via the admin add-member route.
    common::add_member_to_group(&client, &base, &owner_tok, &grp_big, &user_b_id).await;
    common::add_member_to_group(&client, &base, &owner_tok, &grp_big, &user_c_id).await;
    // grp_small stays with just the owner (1 member).

    // List from user_b's perspective, searching by tag so we only see our groups.
    let groups = search_public_groups(&client, &base, &user_b_tok, tag).await;

    // Find our two groups in the list.
    let find = |gid: &str| {
        groups
            .iter()
            .find(|g| g["id"].as_str() == Some(gid))
            .cloned()
    };
    let big_entry = find(&grp_big).expect("BigGroup must appear in search results");
    let small_entry = find(&grp_small).expect("SmallGroup must appear in search results");

    // member_count assertions.
    assert_eq!(
        big_entry["member_count"].as_i64().unwrap(),
        3,
        "BigGroup should have 3 members"
    );
    assert_eq!(
        small_entry["member_count"].as_i64().unwrap(),
        1,
        "SmallGroup should have 1 member"
    );

    // Ordering: big group must appear before small group.
    let big_pos = groups
        .iter()
        .position(|g| g["id"].as_str() == Some(&grp_big))
        .unwrap();
    let small_pos = groups
        .iter()
        .position(|g| g["id"].as_str() == Some(&grp_small))
        .unwrap();
    assert!(
        big_pos < small_pos,
        "BigGroup (pos {big_pos}) should sort before SmallGroup (pos {small_pos})"
    );

    // is_member: user_b is in grp_big but not grp_small.
    assert!(
        big_entry["is_member"].as_bool().unwrap(),
        "user_b should be a member of BigGroup"
    );
    assert!(
        !small_entry["is_member"].as_bool().unwrap(),
        "user_b should not be a member of SmallGroup"
    );

    // user_c is also in grp_big.
    let groups_c = search_public_groups(&client, &base, &user_c_tok, tag).await;
    let big_c = groups_c
        .iter()
        .find(|g| g["id"].as_str() == Some(&grp_big))
        .unwrap();
    assert!(
        big_c["is_member"].as_bool().unwrap(),
        "user_c should be a member of BigGroup"
    );
}

/// Verify that joining via the public join route increments member_count and
/// that leaving (remove_member path) decrements it.
#[tokio::test]
async fn member_count_increments_on_join_decrements_on_leave() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let tag = &uuid::Uuid::new_v4().simple().to_string()[..8];
    let grp_name = format!("JoinLeave_{tag}");

    let (owner_tok, _owner_id, _) =
        common::register_and_login(&client, &base, "mc_join_owner").await;
    let (joiner_tok, _joiner_id, _) = common::register_and_login(&client, &base, "mc_joiner").await;

    let grp = create_public_group(&client, &base, &owner_tok, &grp_name).await;

    // Baseline: 1 member (owner).
    let groups = search_public_groups(&client, &base, &joiner_tok, tag).await;
    let entry = groups
        .iter()
        .find(|g| g["id"].as_str() == Some(&grp))
        .expect("group must be listed");
    assert_eq!(
        entry["member_count"].as_i64().unwrap(),
        1,
        "baseline member_count should be 1"
    );

    // Joiner joins via the public join endpoint.
    join_group(&client, &base, &joiner_tok, &grp).await;

    let groups = search_public_groups(&client, &base, &joiner_tok, tag).await;
    let entry = groups
        .iter()
        .find(|g| g["id"].as_str() == Some(&grp))
        .expect("group must still be listed");
    assert_eq!(
        entry["member_count"].as_i64().unwrap(),
        2,
        "member_count should be 2 after join"
    );
    assert!(
        entry["is_member"].as_bool().unwrap(),
        "joiner should now be is_member=true"
    );

    // Joiner leaves.
    leave_group(&client, &base, &joiner_tok, &grp).await;

    let groups = search_public_groups(&client, &base, &owner_tok, tag).await;
    let entry = groups
        .iter()
        .find(|g| g["id"].as_str() == Some(&grp))
        .expect("group must still be listed");
    assert_eq!(
        entry["member_count"].as_i64().unwrap(),
        1,
        "member_count should return to 1 after leave"
    );
}

/// Verify that the admin add-member + kick (remove-member) paths also maintain
/// member_count correctly.
#[tokio::test]
async fn member_count_maintained_via_admin_add_remove() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let tag = &uuid::Uuid::new_v4().simple().to_string()[..8];
    let grp_name = format!("AdminAddRemove_{tag}");

    let (owner_tok, _owner_id, _) =
        common::register_and_login(&client, &base, "mc_admin_owner").await;
    let (member_tok, member_id, _) =
        common::register_and_login(&client, &base, "mc_admin_member").await;
    let (viewer_tok, _, _) = common::register_and_login(&client, &base, "mc_admin_viewer").await;

    let grp = create_public_group(&client, &base, &owner_tok, &grp_name).await;

    // Owner adds member.
    common::add_member_to_group(&client, &base, &owner_tok, &grp, &member_id).await;

    let groups = search_public_groups(&client, &base, &viewer_tok, tag).await;
    let entry = groups
        .iter()
        .find(|g| g["id"].as_str() == Some(&grp))
        .unwrap();
    assert_eq!(
        entry["member_count"].as_i64().unwrap(),
        2,
        "after admin add, member_count should be 2"
    );

    // Owner kicks member.
    let resp = client
        .delete(format!("{base}/api/groups/{grp}/members/{member_id}"))
        .header("Authorization", format!("Bearer {owner_tok}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "kick should 200");

    let groups = search_public_groups(&client, &base, &viewer_tok, tag).await;
    let entry = groups
        .iter()
        .find(|g| g["id"].as_str() == Some(&grp))
        .unwrap();
    assert_eq!(
        entry["member_count"].as_i64().unwrap(),
        1,
        "after kick, member_count should return to 1"
    );

    // member_tok should no longer see is_member for that group.
    let groups_m = search_public_groups(&client, &base, &member_tok, tag).await;
    let entry_m = groups_m
        .iter()
        .find(|g| g["id"].as_str() == Some(&grp))
        .unwrap();
    assert!(
        !entry_m["is_member"].as_bool().unwrap(),
        "kicked member should have is_member=false"
    );
}
