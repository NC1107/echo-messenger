//! Integration tests for group membership management:
//! add_member, remove_member, ban_member, unban_member,
//! after_member_loss (auto-delete + key rotation), broadcast_member_system_message.

mod common;

use reqwest::Client;
use sqlx::Row;

// ---------------------------------------------------------------------------
// DB helpers (shared with group_key_rotation_on_kick pattern)
// ---------------------------------------------------------------------------

async fn db_pool() -> sqlx::PgPool {
    let url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    echo_server::db::create_pool(&url).await
}

/// Flip `is_encrypted = true` on a conversation for testing key-rotation paths.
async fn flip_encrypted(group_id: &str) {
    let pool = db_pool().await;
    sqlx::query("UPDATE conversations SET is_encrypted = true WHERE id = $1")
        .bind(uuid::Uuid::parse_str(group_id).unwrap())
        .execute(&pool)
        .await
        .expect("flip is_encrypted failed");
}

/// Fetch the `key_version` column for a conversation.
async fn key_version(group_id: &str) -> i32 {
    let pool = db_pool().await;
    let row = sqlx::query("SELECT key_version FROM conversations WHERE id = $1")
        .bind(uuid::Uuid::parse_str(group_id).unwrap())
        .fetch_one(&pool)
        .await
        .expect("fetch key_version failed");
    row.get::<i32, _>("key_version")
}

/// Count rows in `group_key_envelopes` for a conversation.
async fn envelope_count(group_id: &str) -> i64 {
    let pool = db_pool().await;
    let row =
        sqlx::query("SELECT COUNT(*) AS n FROM group_key_envelopes WHERE conversation_id = $1")
            .bind(uuid::Uuid::parse_str(group_id).unwrap())
            .fetch_one(&pool)
            .await
            .expect("count envelopes failed");
    row.get::<i64, _>("n")
}

/// Check whether a conversation row still exists (auto-delete guard).
async fn conversation_exists(group_id: &str) -> bool {
    let pool = db_pool().await;
    let row: (bool,) = sqlx::query_as("SELECT EXISTS(SELECT 1 FROM conversations WHERE id = $1)")
        .bind(uuid::Uuid::parse_str(group_id).unwrap())
        .fetch_one(&pool)
        .await
        .expect("conversation_exists query failed");
    row.0
}

/// Count `banned_members` rows for a given group+user pair.
async fn ban_count(group_id: &str, user_id: &str) -> i64 {
    let pool = db_pool().await;
    let row: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM banned_members \
         WHERE conversation_id = $1 AND user_id = $2",
    )
    .bind(uuid::Uuid::parse_str(group_id).unwrap())
    .bind(uuid::Uuid::parse_str(user_id).unwrap())
    .fetch_one(&pool)
    .await
    .expect("ban_count query failed");
    row.0
}

/// Count system messages of a given kind in a conversation.
async fn sys_msg_count(group_id: &str, kind: &str) -> i64 {
    let pool = db_pool().await;
    let pattern = format!("__system__:{kind}:%");
    let row: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM messages \
         WHERE conversation_id = $1 AND content LIKE $2 AND deleted_at IS NULL",
    )
    .bind(uuid::Uuid::parse_str(group_id).unwrap())
    .bind(&pattern)
    .fetch_one(&pool)
    .await
    .expect("sys_msg_count query failed");
    row.0
}

/// Upload v1 envelopes for a slice of user IDs.
async fn upload_envelopes(
    client: &Client,
    base: &str,
    owner_token: &str,
    group_id: &str,
    member_ids: &[&str],
) {
    let envelopes: Vec<_> = member_ids
        .iter()
        .map(|uid| serde_json::json!({ "user_id": uid, "encrypted_key": format!("env-{uid}") }))
        .collect();
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "key_version": 1, "envelopes": envelopes }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "envelope upload should 201");
}

// ---------------------------------------------------------------------------
// add_member
// ---------------------------------------------------------------------------

/// Happy path: owner adds a new user → 200, member row exists, system message.
#[tokio::test]
async fn add_member_happy_path() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "am_own").await;
    let (_, new_id, new_username) = common::register_and_login(&client, &base, "am_new").await;

    let gid = common::create_group(&client, &base, &owner_token, "AddMemberGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{gid}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": new_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "added");

    // Member row must exist
    let pool = db_pool().await;
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS(\
             SELECT 1 FROM conversation_members \
             WHERE conversation_id = $1 AND user_id = $2 AND is_removed = false\
         )",
    )
    .bind(uuid::Uuid::parse_str(&gid).unwrap())
    .bind(uuid::Uuid::parse_str(&new_id).unwrap())
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(row.0, "member row should exist after add");

    // System message emitted for the member_joined event
    let count = sys_msg_count(&gid, "member_joined").await;
    assert_eq!(count, 1, "expected one member_joined system message");

    let _ = new_username;
}

/// Non-admin regular member cannot add to a private group → 401.
#[tokio::test]
async fn add_member_non_admin_private_group_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "amna_own").await;
    let (member_token, member_id, _) = common::register_and_login(&client, &base, "amna_mem").await;
    let (_, outsider_id, _) = common::register_and_login(&client, &base, "amna_out").await;

    let gid = common::create_group(&client, &base, &owner_token, "PrivGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;

    // Regular member tries to add outsider to a private group
    let resp = client
        .post(format!("{base}/api/groups/{gid}/members"))
        .header("Authorization", format!("Bearer {member_token}"))
        .json(&serde_json::json!({ "user_id": outsider_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

/// Target user does not exist → 404. TD-34.
#[tokio::test]
async fn add_member_nonexistent_user_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "amnx_own").await;

    let gid = common::create_group(&client, &base, &owner_token, "Ghost404Group").await;
    let ghost_id = uuid::Uuid::new_v4().to_string();

    let resp = client
        .post(format!("{base}/api/groups/{gid}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": ghost_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

/// Target user is already a member → 409.
#[tokio::test]
async fn add_member_already_member_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "am409_own").await;

    let gid = common::create_group(&client, &base, &owner_token, "Dup409Group").await;

    // Owner is already a member — second add must 409
    let resp = client
        .post(format!("{base}/api/groups/{gid}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": owner_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 409);
}

/// Banned user cannot be added back → 400.
#[tokio::test]
async fn add_member_banned_user_blocked() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "amban_own").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "amban_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "BanAddGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    // Ban the user
    let ban_resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(ban_resp.status().as_u16(), 200, "ban should succeed");

    // Now try to add the banned user back
    let resp = client
        .post(format!("{base}/api/groups/{gid}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": target_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "banned user should be blocked from add"
    );
}

// ---------------------------------------------------------------------------
// remove_member
// ---------------------------------------------------------------------------

/// Happy path: owner removes member → 200 + system message.
#[tokio::test]
async fn remove_member_happy_path() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "rm_own").await;
    let (_, member_id, _) = common::register_and_login(&client, &base, "rm_mem").await;

    let gid = common::create_group(&client, &base, &owner_token, "RemoveGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;

    let resp = client
        .delete(format!("{base}/api/groups/{gid}/members/{member_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "removed");

    // System message emitted
    let count = sys_msg_count(&gid, "member_removed").await;
    assert_eq!(count, 1, "expected one member_removed system message");
}

/// Non-admin cannot kick another member → 401.
#[tokio::test]
async fn remove_member_non_admin_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "rmna_own").await;
    let (member_token, member_id, _) = common::register_and_login(&client, &base, "rmna_mem").await;
    let (_, other_id, _) = common::register_and_login(&client, &base, "rmna_oth").await;

    let gid = common::create_group(&client, &base, &owner_token, "NonAdminKick").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &other_id).await;

    // Regular member tries to kick another member
    let resp = client
        .delete(format!("{base}/api/groups/{gid}/members/{other_id}"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

/// A member can remove themselves (self-removal == leave via remove endpoint).
#[tokio::test]
async fn remove_member_self_removal_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "rmself_own").await;
    let (member_token, member_id, _) =
        common::register_and_login(&client, &base, "rmself_mem").await;

    let gid = common::create_group(&client, &base, &owner_token, "SelfRemoveGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;

    // Member removes themselves
    let resp = client
        .delete(format!("{base}/api/groups/{gid}/members/{member_id}"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "removed");
}

/// Owner cannot be removed by an admin.
#[tokio::test]
async fn remove_member_cannot_remove_owner() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "rmo_own").await;
    let (admin_token, admin_id, _) = common::register_and_login(&client, &base, "rmo_adm").await;

    let gid = common::create_group(&client, &base, &owner_token, "ProtectOwnerGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &admin_id).await;

    // Promote admin (set role via DB to keep tests fast; avoids needing a promote route)
    let pool = db_pool().await;
    sqlx::query(
        "UPDATE conversation_members SET role = 'admin' \
         WHERE conversation_id = $1 AND user_id = $2",
    )
    .bind(uuid::Uuid::parse_str(&gid).unwrap())
    .bind(uuid::Uuid::parse_str(&admin_id).unwrap())
    .execute(&pool)
    .await
    .expect("promote admin failed");

    // Admin tries to kick the owner
    let resp = client
        .delete(format!("{base}/api/groups/{gid}/members/{owner_id}"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "removing owner must return 400"
    );
}

/// after_member_loss: removing the last non-owner member triggers auto-delete of the group.
/// We do this by removing the only non-owner member, leaving only the owner, then the
/// owner removes themselves — group should be deleted.
#[tokio::test]
async fn remove_last_member_auto_deletes_group() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "rmld_own").await;

    let gid = common::create_group(&client, &base, &owner_token, "AutoDeleteGroup").await;

    // Owner removes themselves — no one left → group is auto-deleted
    let resp = client
        .delete(format!("{base}/api/groups/{gid}/members/{owner_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "self-remove should succeed");

    // The conversation row should have been purged
    assert!(
        !conversation_exists(&gid).await,
        "empty group should be auto-deleted after last member leaves"
    );
}

/// Key rotation fires on encrypted group when a member is removed.
#[tokio::test]
async fn remove_member_encrypted_group_rotates_key() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "rmenc_own").await;
    let (_, member_id, _) = common::register_and_login(&client, &base, "rmenc_mem").await;
    let (_, kicked_id, _) = common::register_and_login(&client, &base, "rmenc_kck").await;

    let gid = common::create_group(&client, &base, &owner_token, "EncRotateGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &kicked_id).await;

    flip_encrypted(&gid).await;
    upload_envelopes(
        &client,
        &base,
        &owner_token,
        &gid,
        &[&owner_id, &member_id, &kicked_id],
    )
    .await;

    let v_before = key_version(&gid).await;
    assert_eq!(envelope_count(&gid).await, 3);

    let resp = client
        .delete(format!("{base}/api/groups/{gid}/members/{kicked_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    assert_eq!(
        key_version(&gid).await,
        v_before + 1,
        "key_version should bump on remove from encrypted group"
    );
    assert_eq!(
        envelope_count(&gid).await,
        0,
        "all old envelopes should be purged after rotation"
    );
}

// ---------------------------------------------------------------------------
// ban_member
// ---------------------------------------------------------------------------

/// Happy path: owner bans a member → 200, banned_members row exists, system message.
#[tokio::test]
async fn ban_member_happy_path() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "ban_own").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "ban_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "BanGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    let resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "banned");

    // banned_members row must exist
    assert_eq!(ban_count(&gid, &target_id).await, 1, "ban row should exist");

    // System message emitted
    let count = sys_msg_count(&gid, "member_banned").await;
    assert_eq!(count, 1, "expected one member_banned system message");
}

/// Non-admin cannot ban → 401.
#[tokio::test]
async fn ban_member_non_admin_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "banna_own").await;
    let (member_token, member_id, _) =
        common::register_and_login(&client, &base, "banna_mem").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "banna_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "NonAdminBan").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    let resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_id}"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

/// Banned user cannot rejoin: add_member returns 400 after ban.
#[tokio::test]
async fn ban_member_blocks_rejoin() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "banrej_own").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "banrej_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "BanRejoindGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    // Ban
    let resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Attempt to add back
    let resp = client
        .post(format!("{base}/api/groups/{gid}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": target_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "banned user must be blocked on add_member"
    );
}

/// Ban persists in the banned_members table (banlist).
#[tokio::test]
async fn ban_member_appears_in_banlist() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "banlist_own").await;
    let (_, t1, _) = common::register_and_login(&client, &base, "banlist_t1").await;
    let (_, t2, _) = common::register_and_login(&client, &base, "banlist_t2").await;

    let gid = common::create_group(&client, &base, &owner_token, "BanListGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &t1).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &t2).await;

    // Ban both
    for uid in [&t1, &t2] {
        let resp = client
            .post(format!("{base}/api/groups/{gid}/ban/{uid}"))
            .header("Authorization", format!("Bearer {owner_token}"))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status().as_u16(), 200);
    }

    assert_eq!(ban_count(&gid, &t1).await, 1, "t1 should be banned");
    assert_eq!(ban_count(&gid, &t2).await, 1, "t2 should be banned");
}

/// Admin cannot ban another admin — only owner can.
#[tokio::test]
async fn ban_member_admin_cannot_ban_peer_admin() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "banpeer_own").await;
    let (admin_token, admin_id, _) =
        common::register_and_login(&client, &base, "banpeer_adm").await;
    let (_, target_admin_id, _) = common::register_and_login(&client, &base, "banpeer_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "PeerBanGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &admin_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_admin_id).await;

    // Promote both to admin via DB
    let pool = db_pool().await;
    for uid in [&admin_id, &target_admin_id] {
        sqlx::query(
            "UPDATE conversation_members SET role = 'admin' \
             WHERE conversation_id = $1 AND user_id = $2",
        )
        .bind(uuid::Uuid::parse_str(&gid).unwrap())
        .bind(uuid::Uuid::parse_str(uid).unwrap())
        .execute(&pool)
        .await
        .expect("promote to admin failed");
    }

    // Admin tries to ban a peer admin — must be rejected
    let resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_admin_id}"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400, "admin cannot ban peer admin");
}

// ---------------------------------------------------------------------------
// unban_member
// ---------------------------------------------------------------------------

/// Happy path: owner unbans a banned user → 200, ban row removed.
#[tokio::test]
async fn unban_member_happy_path() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "unban_own").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "unban_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "UnbanGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    // Ban first
    let resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    assert_eq!(ban_count(&gid, &target_id).await, 1);

    // Unban
    let resp = client
        .post(format!("{base}/api/groups/{gid}/unban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "unbanned");

    // Ban row must be gone
    assert_eq!(
        ban_count(&gid, &target_id).await,
        0,
        "ban row should be removed after unban"
    );
}

/// Non-admin cannot unban → 401.
#[tokio::test]
async fn unban_member_non_admin_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "ubna_own").await;
    let (member_token, member_id, _) = common::register_and_login(&client, &base, "ubna_mem").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "ubna_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "NonAdminUnban").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &member_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    // Ban target
    let resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Regular member tries to unban
    let resp = client
        .post(format!("{base}/api/groups/{gid}/unban/{target_id}"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

/// Unbanning a user that was never banned → 400.
#[tokio::test]
async fn unban_member_not_banned_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "ubnb_own").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "ubnb_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "UnbanNoBan").await;

    // target was never added or banned
    let resp = client
        .post(format!("{base}/api/groups/{gid}/unban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

/// After unban the user can be added back successfully.
#[tokio::test]
async fn unban_allows_readd() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _, _) = common::register_and_login(&client, &base, "ubar_own").await;
    let (_, target_id, _) = common::register_and_login(&client, &base, "ubar_tgt").await;

    let gid = common::create_group(&client, &base, &owner_token, "UnbanReadd").await;
    common::add_member_to_group(&client, &base, &owner_token, &gid, &target_id).await;

    // Ban
    let resp = client
        .post(format!("{base}/api/groups/{gid}/ban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Unban
    let resp = client
        .post(format!("{base}/api/groups/{gid}/unban/{target_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Re-add must now succeed
    let resp = client
        .post(format!("{base}/api/groups/{gid}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": target_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "re-add after unban should succeed"
    );
}
