//! Integration tests for `PATCH /api/groups/:id/members/:user_id/role`.
//!
//! Covers:
//! - Owner can promote member → admin and demote admin → member.
//! - Non-owner (admin or regular member) gets 403/401.
//! - Trying to assign the "owner" role is rejected.
//! - Owner cannot change their own role.
//! - Target must be an active member (non-member gets 400).
//! - Target owner's role cannot be changed.

mod common;

use reqwest::Client;

async fn db_pool() -> sqlx::PgPool {
    let url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    echo_server::db::create_pool(&url).await
}

/// Direct DB helper: read the current role for a (group, user) pair.
async fn member_role(group_id: &str, user_id: &str) -> Option<String> {
    let pool = db_pool().await;
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT role FROM conversation_members \
         WHERE conversation_id = $1 AND user_id = $2 AND is_removed = false",
    )
    .bind(uuid::Uuid::parse_str(group_id).unwrap())
    .bind(uuid::Uuid::parse_str(user_id).unwrap())
    .fetch_optional(&pool)
    .await
    .expect("member_role query failed");
    row.map(|(r,)| r)
}

// ---------------------------------------------------------------------------
// Happy paths
// ---------------------------------------------------------------------------

/// Owner promotes a regular member to admin; DB reflects the change.
#[tokio::test]
async fn promote_member_to_admin_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "cr_prm_own").await;
    let (_, member_id, _) = common::register_and_login(&client, &base, "cr_prm_mem").await;

    let gid = common::create_group(&client, &base, &owner_token, "PromoteGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;

    // Verify starting role is "member"
    assert_eq!(
        member_role(&gid, &member_id).await.as_deref(),
        Some("member")
    );

    let resp = client
        .patch(format!("{base}/api/groups/{gid}/members/{member_id}/role"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "role": "admin" }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "owner promote should return 200"
    );

    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["role"], "admin");
    assert_eq!(body["user_id"], member_id);

    // DB must reflect the promotion
    assert_eq!(
        member_role(&gid, &member_id).await.as_deref(),
        Some("admin"),
        "role should be admin after promotion"
    );
}

/// Owner demotes an admin back to regular member.
#[tokio::test]
async fn demote_admin_to_member_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "cr_dem_own").await;
    let (_, admin_id, _) = common::register_and_login(&client, &base, "cr_dem_adm").await;

    let gid = common::create_group(&client, &base, &owner_token, "DemoteGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &admin_id).await;

    // Promote first via DB shortcut (mirrors existing test patterns)
    let pool = db_pool().await;
    sqlx::query(
        "UPDATE conversation_members SET role = 'admin' \
         WHERE conversation_id = $1 AND user_id = $2",
    )
    .bind(uuid::Uuid::parse_str(&gid).unwrap())
    .bind(uuid::Uuid::parse_str(&admin_id).unwrap())
    .execute(&pool)
    .await
    .expect("seed admin role");

    assert_eq!(member_role(&gid, &admin_id).await.as_deref(), Some("admin"));

    let resp = client
        .patch(format!("{base}/api/groups/{gid}/members/{admin_id}/role"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "role": "member" }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "owner demote should return 200"
    );

    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["role"], "member");

    assert_eq!(
        member_role(&gid, &admin_id).await.as_deref(),
        Some("member"),
        "role should be member after demotion"
    );
}

// ---------------------------------------------------------------------------
// Authorization guards
// ---------------------------------------------------------------------------

/// A regular member (non-admin) cannot change any role → 403.
#[tokio::test]
async fn regular_member_cannot_change_role_returns_403() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "cr_noauth_own").await;
    let (member_token, member_id, _) =
        common::register_and_login(&client, &base, "cr_noauth_mem").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "cr_noauth_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "NoAuthGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    let resp = client
        .patch(format!("{base}/api/groups/{gid}/members/{target_id}/role"))
        .header("Authorization", format!("Bearer {member_token}"))
        .json(&serde_json::json!({ "role": "admin" }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        403,
        "regular member must not change roles"
    );
}

/// An admin (non-owner) cannot change roles → 403.
#[tokio::test]
async fn admin_cannot_change_role_returns_403() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "cr_adm_own").await;
    let (admin_token, admin_id, _) = common::register_and_login(&client, &base, "cr_adm_adm").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "cr_adm_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "AdminNoPromote").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &admin_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    // Promote caller to admin via DB
    let pool = db_pool().await;
    sqlx::query(
        "UPDATE conversation_members SET role = 'admin' \
         WHERE conversation_id = $1 AND user_id = $2",
    )
    .bind(uuid::Uuid::parse_str(&gid).unwrap())
    .bind(uuid::Uuid::parse_str(&admin_id).unwrap())
    .execute(&pool)
    .await
    .expect("seed admin role");

    let resp = client
        .patch(format!("{base}/api/groups/{gid}/members/{target_id}/role"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .json(&serde_json::json!({ "role": "admin" }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        403,
        "admin must not promote other members"
    );
}

// ---------------------------------------------------------------------------
// Immutability guards
// ---------------------------------------------------------------------------

/// Requesting the "owner" role is rejected with 400.
#[tokio::test]
async fn assign_owner_role_rejected_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "cr_ownr_own").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "cr_ownr_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "NoOwnerGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    let resp = client
        .patch(format!("{base}/api/groups/{gid}/members/{target_id}/role"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "role": "owner" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400, "assigning owner role must 400");
}

/// Owner cannot change their own role.
#[tokio::test]
async fn owner_cannot_change_own_role_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) =
        common::register_and_login(&client, &base, "cr_self_own").await;

    let gid = common::create_group(&client, &base, &owner_token, "SelfRoleGroup").await;

    let resp = client
        .patch(format!("{base}/api/groups/{gid}/members/{owner_id}/role"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "role": "member" }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "owner changing own role must 400"
    );
}

/// Attempting to change the role of a non-member returns 400.
#[tokio::test]
async fn change_role_of_non_member_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "cr_noMem_own").await;
    let (_, outsider_id, _) = common::register_and_login(&client, &base, "cr_noMem_out").await;

    let gid = common::create_group(&client, &base, &owner_token, "OutsiderGroup").await;
    // outsider is NOT added to the group

    let resp = client
        .patch(format!(
            "{base}/api/groups/{gid}/members/{outsider_id}/role"
        ))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "role": "admin" }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "non-member target must return 400"
    );
}
