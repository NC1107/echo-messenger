//! Beta-prep #4 — admin stats + feedback listing endpoints.
//!
//! Covers:
//!  - 403 for callers without `is_admin = TRUE`
//!  - 200 for an explicitly-promoted admin with the expected JSON shape
//!  - 200 for `GET /api/admin/feedback?status=open`

mod common;

use common::{register_and_login, spawn_server, test_pool};
use reqwest::Client;
use uuid::Uuid;

/// Promote a user to admin by UPDATE-ing the DB directly (the only way --
/// there is intentionally no public API for this).
async fn promote_to_admin(user_id: &str) {
    let pool = test_pool().await;
    let id = Uuid::parse_str(user_id).expect("valid user_id");
    sqlx::query("UPDATE users SET is_admin = TRUE WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .expect("promote to admin");
}

#[tokio::test]
async fn admin_stats_rejects_non_admin() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, _, _) = register_and_login(&client, &base, "stats_plain").await;

    let resp = client
        .get(format!("{base}/api/admin/stats"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 403);
}

#[tokio::test]
async fn admin_stats_returns_payload_for_admin() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, user_id, _) = register_and_login(&client, &base, "stats_admin").await;
    promote_to_admin(&user_id).await;

    let resp = client
        .get(format!("{base}/api/admin/stats"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    let body: serde_json::Value = resp.json().await.unwrap();
    for key in [
        "users_total",
        "users_active_24h",
        "messages_24h",
        "groups_total",
        "online_devices",
        "feedback_open",
        "feedback_last_24h",
    ] {
        assert!(
            body[key].is_i64() || body[key].is_u64(),
            "expected integer for {key} in {body}"
        );
    }
}

#[tokio::test]
async fn admin_feedback_list_returns_open_reports() {
    let base = spawn_server().await;
    let client = Client::new();

    // A regular user files a report.
    let (reporter_token, _, _) = register_and_login(&client, &base, "fb_reporter").await;
    let resp = client
        .post(format!("{base}/api/feedback"))
        .header("Authorization", format!("Bearer {reporter_token}"))
        .json(&serde_json::json!({
            "title": "Visible to admin",
            "body": "This row should appear in the admin inbox.",
            "public_ok": true,
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);

    // A separate user, promoted to admin, reads the inbox.
    let (admin_token, admin_id, _) = register_and_login(&client, &base, "fb_admin").await;
    promote_to_admin(&admin_id).await;

    let resp = client
        .get(format!("{base}/api/admin/feedback?status=open"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    let body: serde_json::Value = resp.json().await.unwrap();
    let rows = body["feedback"].as_array().expect("feedback array");
    assert!(
        rows.iter().any(|r| r["title"] == "Visible to admin"),
        "expected our report to appear in the inbox, got {body}"
    );
}

#[tokio::test]
async fn admin_feedback_list_rejects_invalid_status() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, user_id, _) = register_and_login(&client, &base, "fb_admin_bad").await;
    promote_to_admin(&user_id).await;

    let resp = client
        .get(format!("{base}/api/admin/feedback?status=banana"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}
