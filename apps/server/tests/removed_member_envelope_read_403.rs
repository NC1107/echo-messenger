//! #656 — a member who has been kicked from an encrypted group must lose
//! access to the group's key envelopes via `/api/groups/:id/keys/latest`.
//! Since the existing route uses `is_member` (which excludes soft-removed
//! rows), the kicked user gets the standard "not a member" rejection rather
//! than data leak.

mod common;

use reqwest::Client;

#[tokio::test]
async fn kicked_member_envelope_read_returns_unauthorized() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "kremown").await;
    let (victim_token, victim_id, _) = common::register_and_login(&client, &base, "kremvic").await;

    let group_id = common::create_group(&client, &base, &owner_token, "KickedReadBlocked").await;
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &victim_id).await;

    // Flip to encrypted and seed v1 envelopes.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;
    sqlx::query("UPDATE conversations SET is_encrypted = true WHERE id = $1")
        .bind(uuid::Uuid::parse_str(&group_id).unwrap())
        .execute(&pool)
        .await
        .unwrap();

    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "owner-env" },
            { "user_id": victim_id, "encrypted_key": "victim-env" },
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

    // Sanity: while still a member, victim CAN read.
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {victim_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "active member can read");

    // Kick.
    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/members/{victim_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // After kick, victim must be locked out of envelope reads.
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {victim_token}"))
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    assert!(
        status == 401 || status == 403 || status == 404,
        "kicked member envelope read must be rejected, got {status}"
    );

    // And specifically by version too.
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/1"))
        .header("Authorization", format!("Bearer {victim_token}"))
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    assert!(
        status == 401 || status == 403 || status == 404,
        "kicked member versioned envelope read must be rejected, got {status}"
    );
}
