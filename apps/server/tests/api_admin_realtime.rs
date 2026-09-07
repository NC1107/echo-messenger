//! Admin dashboard Phase 1 (#681) — realtime stats + promotion endpoint.
//!
//! Covers:
//! - `GET /api/admin/stats/realtime` rejects non-admin with 403
//! - `GET /api/admin/stats/realtime` returns the expected JSON shape for an
//!   admin with a fresh token
//! - `POST /api/admin/promote/{user_id}` flips `is_admin` and returns 200
//! - `POST /api/admin/promote/{user_id}` returns 404 for an unknown user
//! - A stale access token (issued more than the 5-minute re-auth window
//!   ago) returns 401 plus `WWW-Authenticate: Bearer error="reauth_required"`

mod common;

use common::{TEST_JWT_SECRET, register_and_login, spawn_server, test_pool};
use jsonwebtoken::{EncodingKey, Header, encode};
use reqwest::Client;
use serde::Serialize;
use uuid::Uuid;

async fn promote_via_db(user_id: &str) {
    let pool = test_pool().await;
    let id = Uuid::parse_str(user_id).expect("valid user_id");
    sqlx::query("UPDATE users SET is_admin = TRUE WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .expect("promote to admin");
}

/// Force a user OFF the admin role. Necessary for tests that depend on a
/// non-admin caller: on a fresh / cleanly-truncated DB the very first
/// registered user gets `is_admin=TRUE` via the bootstrap rule shipped
/// in #1066. If the test happens to register that first user it would
/// accidentally land as admin and the "rejects non-admin" assertion
/// would fail under integer-200 instead of the expected 403.
async fn demote_via_db(user_id: &str) {
    let pool = test_pool().await;
    let id = Uuid::parse_str(user_id).expect("valid user_id");
    sqlx::query("UPDATE users SET is_admin = FALSE WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .expect("demote from admin");
}

#[tokio::test]
async fn realtime_stats_rejects_non_admin() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, user_id, _) = register_and_login(&client, &base, "rt_plain").await;
    // Guard against the first-user-becomes-admin bootstrap when this
    // test happens to register the first user in a fresh DB. We want a
    // genuine non-admin caller here.
    demote_via_db(&user_id).await;

    let resp = client
        .get(format!("{base}/api/admin/stats/realtime"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 403);
}

#[tokio::test]
async fn realtime_stats_returns_expected_shape_for_admin() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, user_id, _) = register_and_login(&client, &base, "rt_admin").await;
    promote_via_db(&user_id).await;

    let resp = client
        .get(format!("{base}/api/admin/stats/realtime"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    let body: serde_json::Value = resp.json().await.unwrap();

    for key in [
        "connected_sessions",
        "active_voice_rooms",
        "db_pool_in_flight",
        "db_pool_max",
    ] {
        assert!(
            body[key].is_u64() || body[key].is_i64(),
            "expected integer for {key} in {body}"
        );
    }
    assert!(
        body["messages_per_sec"].is_f64() || body["messages_per_sec"].is_i64(),
        "expected number for messages_per_sec in {body}"
    );

    let platforms = &body["connected_sessions_by_platform"];
    for key in ["web", "mobile", "desktop", "unknown"] {
        assert!(
            platforms[key].is_u64() || platforms[key].is_i64(),
            "missing platform key {key} in {body}"
        );
    }
}

#[tokio::test]
async fn promote_user_flips_is_admin() {
    let base = spawn_server().await;
    let client = Client::new();

    let (admin_token, admin_id, _) = register_and_login(&client, &base, "promote_caller").await;
    promote_via_db(&admin_id).await;

    let (_target_token, target_id, target_username) =
        register_and_login(&client, &base, "promote_target").await;

    let resp = client
        .post(format!("{base}/api/admin/promote/{target_id}"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["id"], target_id);
    assert_eq!(body["username"], target_username);
    assert_eq!(body["is_admin"], true);
    // Defense-in-depth: server must not echo the password hash.
    assert!(
        body.get("password_hash").is_none(),
        "promote response leaked password_hash: {body}"
    );

    // Verify the row actually flipped.
    let pool = test_pool().await;
    let (is_admin,): (bool,) = sqlx::query_as("SELECT is_admin FROM users WHERE id = $1")
        .bind(Uuid::parse_str(&target_id).unwrap())
        .fetch_one(&pool)
        .await
        .unwrap();
    assert!(is_admin);
}

#[tokio::test]
async fn promote_user_returns_404_for_unknown_user() {
    let base = spawn_server().await;
    let client = Client::new();
    let (admin_token, admin_id, _) = register_and_login(&client, &base, "promote_404").await;
    promote_via_db(&admin_id).await;

    let missing = Uuid::new_v4();
    let resp = client
        .post(format!("{base}/api/admin/promote/{missing}"))
        .header("Authorization", format!("Bearer {admin_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

/// Mint a JWT with a deliberately-old `iat`/`exp` that still validates
/// against the test signing secret, but falls outside the 5-minute admin
/// re-auth window.
fn mint_token_with_iat(user_id: Uuid, iat_seconds_ago: i64) -> String {
    #[derive(Serialize)]
    struct ClaimsLike {
        sub: String,
        exp: usize,
        iat: usize,
        iss: String,
        aud: String,
    }
    let now = chrono::Utc::now().timestamp();
    let claims = ClaimsLike {
        sub: user_id.to_string(),
        exp: (now + 3600) as usize,
        iat: (now - iat_seconds_ago) as usize,
        iss: "echo-messenger".to_string(),
        aud: "echo-app".to_string(),
    };
    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(TEST_JWT_SECRET.as_bytes()),
    )
    .expect("sign admin reauth test token")
}

#[tokio::test]
async fn stale_admin_token_returns_reauth_required() {
    let base = spawn_server().await;
    let client = Client::new();
    let (_token, user_id, _) = register_and_login(&client, &base, "stale_admin").await;
    promote_via_db(&user_id).await;

    let uid = Uuid::parse_str(&user_id).unwrap();
    // 30 minutes > 5-minute window. Token is still cryptographically valid
    // (exp is +1h), but `iat` is stale.
    let stale_token = mint_token_with_iat(uid, 30 * 60);

    let resp = client
        .get(format!("{base}/api/admin/stats/realtime"))
        .header("Authorization", format!("Bearer {stale_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
    let www_auth = resp
        .headers()
        .get(reqwest::header::WWW_AUTHENTICATE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        www_auth.contains("reauth_required"),
        "expected reauth_required hint in WWW-Authenticate header, got {www_auth:?}"
    );
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["code"], "reauth-required");
}

#[tokio::test]
async fn register_response_includes_is_admin_flag() {
    let base = spawn_server().await;
    let client = Client::new();
    // We can't assert "first user is admin" deterministically because the
    // integration tests share one DB and other tests already registered.
    // The contract we *do* enforce is that the field is always present so
    // the client can read it.
    // Username max is 32 chars (see `validate_username` in routes/auth.rs);
    // truncate the UUID suffix so we stay inside the budget.
    let suffix = Uuid::new_v4().simple().to_string();
    let username = format!("admin_flag_{}", &suffix[..8]);
    let password = common::unique_password();
    let resp = client
        .post(format!("{base}/api/auth/register"))
        .json(&serde_json::json!({
            "username": username,
            "password": password,
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(
        body["is_admin"].is_boolean(),
        "register response must surface is_admin, got {body}"
    );
}
