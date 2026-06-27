//! Admin feedback deletion — `DELETE /api/admin/feedback/{id}`.
//!
//! The operator inbox grew unbounded with no way to clear reports. Covers:
//!  - 204 + row gone from the inbox after an admin deletes it
//!  - 404 for an unknown id
//!  - 403 for a non-admin caller

mod common;

use common::{register_and_login, spawn_server, test_pool};
use reqwest::Client;
use uuid::Uuid;

async fn promote_to_admin(user_id: &str) {
    let pool = test_pool().await;
    let id = Uuid::parse_str(user_id).expect("valid user_id");
    sqlx::query("UPDATE users SET is_admin = TRUE WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .expect("promote to admin");
}

/// File one feedback report and return its id.
async fn file_feedback(client: &Client, base: &str, token: &str, title: &str) -> String {
    let resp = client
        .post(format!("{base}/api/feedback"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "title": title,
            "body": "body text",
            "public_ok": false,
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: serde_json::Value = resp.json().await.unwrap();
    body["feedback_id"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn admin_can_delete_feedback() {
    let base = spawn_server().await;
    let client = Client::new();

    let (reporter_token, _, _) = register_and_login(&client, &base, "del_reporter").await;
    let fb_id = file_feedback(&client, &base, &reporter_token, "delete me").await;

    let (admin_token, admin_id, _) = register_and_login(&client, &base, "del_admin").await;
    promote_to_admin(&admin_id).await;

    let resp = client
        .delete(format!("{base}/api/admin/feedback/{fb_id}"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 204);

    // The row should no longer appear in the open inbox.
    let resp = client
        .get(format!("{base}/api/admin/feedback?status=open"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .send()
        .await
        .unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    let rows = body["feedback"].as_array().expect("feedback array");
    assert!(
        !rows.iter().any(|r| r["id"] == fb_id),
        "deleted report should be gone from inbox, got {body}"
    );
}

#[tokio::test]
async fn delete_unknown_feedback_returns_404() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, user_id, _) = register_and_login(&client, &base, "del_404").await;
    promote_to_admin(&user_id).await;

    let missing = Uuid::new_v4();
    let resp = client
        .delete(format!("{base}/api/admin/feedback/{missing}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn delete_feedback_rejects_non_admin() {
    let base = spawn_server().await;
    let client = Client::new();

    // The very first registrant on a fresh server is auto-promoted to admin
    // (bootstrap rule), so burn that slot on a throwaway before registering
    // the genuinely non-admin reporter.
    let _ = register_and_login(&client, &base, "del_bootstrap_admin").await;
    let (reporter_token, _, _) = register_and_login(&client, &base, "del_plain_rep").await;
    let fb_id = file_feedback(&client, &base, &reporter_token, "keep me").await;

    // The reporter (not an admin) tries to delete — 403.
    let resp = client
        .delete(format!("{base}/api/admin/feedback/{fb_id}"))
        .header("Authorization", format!("Bearer {reporter_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 403);
}
