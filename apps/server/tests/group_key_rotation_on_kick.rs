//! #656 — group-key rotation on member kick.
//!
//! Verifies that when an encrypted group has a member removed, the server
//! atomically:
//!
//! - bumps the conversation's `key_version`,
//! - deletes every existing `group_key_envelopes` row for the conversation
//!   (including envelopes for the kicked member), and
//! - the kicked member can no longer fetch a current envelope.

mod common;

use reqwest::Client;
use sqlx::Row;

async fn pool() -> sqlx::PgPool {
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    echo_server::db::create_pool(&database_url).await
}

async fn flip_encrypted(group_id: &str) {
    let pool = pool().await;
    sqlx::query("UPDATE conversations SET is_encrypted = true WHERE id = $1")
        .bind(uuid::Uuid::parse_str(group_id).unwrap())
        .execute(&pool)
        .await
        .expect("flip is_encrypted failed");
}

async fn key_version(group_id: &str) -> i32 {
    let pool = pool().await;
    let row = sqlx::query("SELECT key_version FROM conversations WHERE id = $1")
        .bind(uuid::Uuid::parse_str(group_id).unwrap())
        .fetch_one(&pool)
        .await
        .expect("fetch key_version failed");
    row.get::<i32, _>("key_version")
}

async fn envelope_count(group_id: &str) -> i64 {
    let pool = pool().await;
    let row =
        sqlx::query("SELECT COUNT(*) AS n FROM group_key_envelopes WHERE conversation_id = $1")
            .bind(uuid::Uuid::parse_str(group_id).unwrap())
            .fetch_one(&pool)
            .await
            .expect("count envelopes failed");
    row.get::<i64, _>("n")
}

async fn upload_envelopes_v1(
    client: &Client,
    base: &str,
    owner_token: &str,
    group_id: &str,
    member_ids: &[&str],
) {
    let envelopes: Vec<_> = member_ids
        .iter()
        .map(|uid| serde_json::json!({ "user_id": uid, "encrypted_key": format!("env-for-{uid}") }))
        .collect();

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({
            "key_version": 1,
            "envelopes": envelopes,
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "v1 envelope upload should 201");
}

#[tokio::test]
async fn kick_on_encrypted_group_bumps_key_version_and_purges_envelopes() {
    let base = common::spawn_server().await;
    let client = Client::new();

    // Register-rate-limit budget per server is tight (3 / 60s per IP), so we
    // stay at exactly 3 distinct accounts: owner + a remaining member + the
    // doomed kicked member.
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "rotown").await;
    let (_alice_token, alice_id, _) = common::register_and_login(&client, &base, "rotalice").await;
    let (_kicked_token, kicked_id, _) = common::register_and_login(&client, &base, "rotkick").await;

    let group_id = common::create_group(&client, &base, &owner_token, "RotateGroup").await;
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &alice_id).await;
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &kicked_id).await;

    flip_encrypted(&group_id).await;

    upload_envelopes_v1(
        &client,
        &base,
        &owner_token,
        &group_id,
        &[&owner_id, &alice_id, &kicked_id],
    )
    .await;

    let v_before = key_version(&group_id).await;
    assert_eq!(envelope_count(&group_id).await, 3);

    // Kick the doomed member.
    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/members/{kicked_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "kick should 200");

    let v_after = key_version(&group_id).await;
    assert_eq!(
        v_after,
        v_before + 1,
        "key_version should bump exactly once on kick"
    );
    assert_eq!(
        envelope_count(&group_id).await,
        0,
        "all old envelopes (including for kicked user) should be deleted"
    );

    // Sanity: a remaining member's GET now misses the envelope (rotation
    // pending the client-side regeneration), so the API falls back through
    // the legacy group_keys row OR returns 400 — either way, no live envelope
    // exists for them right now. We just assert no envelope row is present.
    let pool = pool().await;
    let alice_uuid = uuid::Uuid::parse_str(&alice_id).unwrap();
    let group_uuid = uuid::Uuid::parse_str(&group_id).unwrap();
    let alice_envs: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM group_key_envelopes \
         WHERE conversation_id = $1 AND recipient_user_id = $2",
    )
    .bind(group_uuid)
    .bind(alice_uuid)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(alice_envs, 0);
}

#[tokio::test]
async fn kick_on_plaintext_group_does_not_rotate() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_token, _owner_id, _) = common::register_and_login(&client, &base, "rotpown").await;
    let (member_token, member_id, _) = common::register_and_login(&client, &base, "rotpmem").await;

    let group_id = common::create_group(&client, &base, &owner_token, "PlaintextRotate").await;
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id).await;

    let v_before = key_version(&group_id).await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/members/{member_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    assert_eq!(
        key_version(&group_id).await,
        v_before,
        "plaintext groups should not bump key_version on kick"
    );

    let _ = member_token;
}
