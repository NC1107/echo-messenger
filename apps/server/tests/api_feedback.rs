//! Beta-prep #4 — feedback endpoint integration tests.
//!
//! Covers:
//!  - happy path (201 + feedback_id)
//!  - rejects unauthenticated callers (401)
//!  - enforces 5/24h rate limit (429 on the 6th report)

mod common;

use common::{register_and_login, spawn_server};
use reqwest::Client;

#[tokio::test]
async fn create_feedback_happy_path() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, _, _) = register_and_login(&client, &base, "fb_happy").await;

    let resp = client
        .post(format!("{base}/api/feedback"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "title": "Login screen looks weird on iOS",
            "body": "The input cursor jumps when I rotate to landscape.",
            "public_ok": true,
        }))
        .send()
        .await
        .expect("feedback request failed");

    assert_eq!(resp.status().as_u16(), 201);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(
        body["feedback_id"].as_str().is_some(),
        "expected feedback_id in response, got {body}"
    );
}

#[tokio::test]
async fn create_feedback_requires_auth() {
    let base = spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/feedback"))
        .json(&serde_json::json!({
            "title": "Anon bug",
            "body": "This should not be accepted.",
        }))
        .send()
        .await
        .expect("feedback request failed");

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn create_feedback_rejects_empty_title() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, _, _) = register_and_login(&client, &base, "fb_empty").await;

    let resp = client
        .post(format!("{base}/api/feedback"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "title": "  ", "body": "Has a body but no title." }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn create_feedback_rate_limit_kicks_in_after_five() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, _, _) = register_and_login(&client, &base, "fb_rate").await;

    // First 5 should succeed.
    for i in 0..5 {
        let resp = client
            .post(format!("{base}/api/feedback"))
            .header("Authorization", format!("Bearer {token}"))
            .json(&serde_json::json!({
                "title": format!("Report {i}"),
                "body": "Filler body to pass validation",
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(
            resp.status().as_u16(),
            201,
            "report {i} should succeed, got {}",
            resp.status()
        );
    }

    // 6th should be rate-limited.
    let resp = client
        .post(format!("{base}/api/feedback"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "title": "Report 6",
            "body": "Should be rate limited",
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 429);
}
