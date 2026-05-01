//! Unit tests for `db::groups::get_member_context` (#691).
//!
//! Covers: active member, removed member, non-member, non-existent conversation.

mod common;

use sqlx::postgres::PgPoolOptions;
use uuid::Uuid;

async fn make_pool() -> sqlx::PgPool {
    let url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    PgPoolOptions::new()
        .max_connections(2)
        .connect(&url)
        .await
        .expect("connect to test db")
}

#[tokio::test]
async fn get_member_context_active_member() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    let (owner_token, _owner_id, _) =
        common::register_and_login(&client, &base, "gmc_owner_active").await;
    let (_, member_id, _) = common::register_and_login(&client, &base, "gmc_member_active").await;

    let group_id_str = common::create_group(&client, &base, &owner_token, "gmc-active-group").await;
    let group_id = Uuid::parse_str(&group_id_str).expect("valid uuid");
    common::add_member_to_group(&client, &base, &owner_token, &group_id_str, &member_id).await;

    let member_uuid = Uuid::parse_str(&member_id).expect("valid uuid");
    let pool = make_pool().await;

    let ctx = echo_server::db::groups::get_member_context(&pool, group_id, member_uuid)
        .await
        .expect("query ok")
        .expect("conversation exists");

    assert!(ctx.is_member, "active member should have is_member=true");
    assert_eq!(ctx.kind, "group");
    assert!(ctx.role.is_some(), "active member should have a role");
}

#[tokio::test]
async fn get_member_context_non_member() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    let (owner_token, _owner_id, _) =
        common::register_and_login(&client, &base, "gmc_owner_nonmem").await;
    let (_, outsider_id, _) = common::register_and_login(&client, &base, "gmc_outsider").await;

    let group_id_str = common::create_group(&client, &base, &owner_token, "gmc-nonmem-group").await;
    let group_id = Uuid::parse_str(&group_id_str).expect("valid uuid");
    let outsider_uuid = Uuid::parse_str(&outsider_id).expect("valid uuid");
    let pool = make_pool().await;

    let ctx = echo_server::db::groups::get_member_context(&pool, group_id, outsider_uuid)
        .await
        .expect("query ok")
        .expect("conversation exists");

    assert!(!ctx.is_member, "non-member should have is_member=false");
    assert_eq!(ctx.kind, "group");
    assert!(ctx.role.is_none(), "non-member should have no role");
}

#[tokio::test]
async fn get_member_context_removed_member() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    let (owner_token, owner_id, _) =
        common::register_and_login(&client, &base, "gmc_owner_removed").await;
    let (_, member_id, _) = common::register_and_login(&client, &base, "gmc_member_removed").await;

    let group_id_str =
        common::create_group(&client, &base, &owner_token, "gmc-removed-group").await;
    let group_id = Uuid::parse_str(&group_id_str).expect("valid uuid");
    common::add_member_to_group(&client, &base, &owner_token, &group_id_str, &member_id).await;

    let owner_uuid = Uuid::parse_str(&owner_id).expect("valid uuid");
    let member_uuid = Uuid::parse_str(&member_id).expect("valid uuid");
    let pool = make_pool().await;

    // Remove the member via SQL directly (simulating kick via DB).
    sqlx::query(
        "UPDATE conversation_members \
         SET is_removed = true, removed_at = NOW() \
         WHERE conversation_id = $1 AND user_id = $2",
    )
    .bind(group_id)
    .bind(member_uuid)
    .execute(&pool)
    .await
    .expect("remove member");

    let ctx = echo_server::db::groups::get_member_context(&pool, group_id, member_uuid)
        .await
        .expect("query ok")
        .expect("conversation exists");

    assert!(!ctx.is_member, "removed member should have is_member=false");
    assert!(ctx.role.is_none(), "removed member should have no role");

    // Owner (still active) should still see is_member=true.
    let owner_ctx = echo_server::db::groups::get_member_context(&pool, group_id, owner_uuid)
        .await
        .expect("query ok")
        .expect("conversation exists");
    assert!(owner_ctx.is_member, "owner should still be a member");
}

#[tokio::test]
async fn get_member_context_non_existent_conversation() {
    let pool = make_pool().await;
    let fake_conv = Uuid::new_v4();
    let fake_user = Uuid::new_v4();

    let result = echo_server::db::groups::get_member_context(&pool, fake_conv, fake_user)
        .await
        .expect("query itself should not error");

    assert!(
        result.is_none(),
        "non-existent conversation should return None"
    );
}
