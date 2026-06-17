//! Integration tests for the notification-snooze endpoint and its
//! interaction with the push-skip helper.
//!
//! See `apps/server/migrations/20260528000000_notification_snooze.sql`
//! and `routes::users::update_snooze`.

mod common;

use chrono::{Duration as ChronoDuration, Utc};
use reqwest::Client;
use serde_json::Value;
use uuid::Uuid;

const SNOOZE_PATH: &str = "/api/users/me/notifications/snooze";

async fn setup_user(client: &Client, base: &str, prefix: &str) -> (String, String) {
    let username = common::unique_username(prefix);
    common::register(client, base, &username, "password123").await;
    common::login(client, base, &username, "password123").await
}

#[tokio::test]
async fn snooze_with_valid_until_persists_and_returned_by_me() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _user_id) = setup_user(&client, &base, "snzset").await;

    let until = Utc::now() + ChronoDuration::hours(2);
    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "until": until.to_rfc3339() }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // GET /api/users/me should now include the same timestamp.
    let me = client
        .get(format!("{base}/api/users/me"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(me.status().as_u16(), 200);
    let body: Value = me.json().await.unwrap();
    let echoed = body["notifications_snoozed_until"]
        .as_str()
        .expect("snooze field missing");
    let parsed = chrono::DateTime::parse_from_rfc3339(echoed).unwrap();
    // Timestamps round-trip to within a second.
    assert!((parsed.with_timezone(&Utc) - until).num_seconds().abs() < 2);
}

#[tokio::test]
async fn snooze_with_duration_hours_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "snzhrs").await;

    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "duration_hours": 8 }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert!(body["notifications_snoozed_until"].is_string());
}

#[tokio::test]
async fn snooze_with_past_until_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "snzpast").await;

    let past = Utc::now() - ChronoDuration::minutes(5);
    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "until": past.to_rfc3339() }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn snooze_with_window_over_seven_days_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "snzlong").await;

    let too_far = Utc::now() + ChronoDuration::days(8);
    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "until": too_far.to_rfc3339() }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);

    // duration_hours variant — 8 days = 192 hours.
    let resp2 = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "duration_hours": 192 }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp2.status().as_u16(), 400);
}

#[tokio::test]
async fn snooze_with_explicit_null_clears() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "snzclr").await;

    // First snooze for an hour.
    let until = Utc::now() + ChronoDuration::hours(1);
    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "until": until.to_rfc3339() }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Clear via explicit null.
    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "until": null }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert!(body["notifications_snoozed_until"].is_null());
}

#[tokio::test]
async fn snooze_endpoint_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .json(&serde_json::json!({ "duration_hours": 1 }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Push-skip behaviour
//
// The push fan-out path calls `db::users::snoozed_user_ids` to decide which
// recipients to drop. APNs is mocked out by the production code path when
// `APNS_KEY_ID` is unset (the test env), so we drive the helper directly to
// prove the skip is correct AND that expired snoozes are lazily cleared.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn snoozed_user_ids_filters_active_snoozes_and_clears_expired() {
    use sqlx::Row;
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token_active, active_id) = setup_user(&client, &base, "snzactive").await;
    let (_token_expired, expired_id) = setup_user(&client, &base, "snzexpired").await;
    let (_token_clean, clean_id) = setup_user(&client, &base, "snzclean").await;

    // Active user snoozes for 1h.
    let until = Utc::now() + ChronoDuration::hours(1);
    let resp = client
        .patch(format!("{base}{SNOOZE_PATH}"))
        .header("Authorization", format!("Bearer {token_active}"))
        .json(&serde_json::json!({ "until": until.to_rfc3339() }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Use the same Postgres the test server uses; mirror common::spawn_server.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect test pg");

    // Hand-set the "expired" user's snooze to 5 minutes ago, bypassing the
    // 400 validator — we are simulating a stale snooze the user set days ago.
    let expired_uuid = Uuid::parse_str(&expired_id).unwrap();
    let stale = Utc::now() - ChronoDuration::minutes(5);
    sqlx::query("UPDATE users SET notifications_snoozed_until = $1 WHERE id = $2")
        .bind(stale)
        .bind(expired_uuid)
        .execute(&pool)
        .await
        .unwrap();

    let active_uuid = Uuid::parse_str(&active_id).unwrap();
    let clean_uuid = Uuid::parse_str(&clean_id).unwrap();

    let snoozed =
        echo_server::db::users::snoozed_user_ids(&pool, &[active_uuid, expired_uuid, clean_uuid])
            .await
            .unwrap();

    // Active user is the only one returned. Expired user is dropped AND
    // their column was lazily cleared as a side-effect.
    assert_eq!(snoozed, vec![active_uuid]);

    let row = sqlx::query("SELECT notifications_snoozed_until FROM users WHERE id = $1")
        .bind(expired_uuid)
        .fetch_one(&pool)
        .await
        .unwrap();
    let cleared: Option<chrono::DateTime<Utc>> = row.get(0);
    assert!(cleared.is_none(), "expired snooze should be lazily cleared");
}
