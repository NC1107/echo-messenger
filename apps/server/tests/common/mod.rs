//! Shared test harness for integration tests.
//!
//! Spins up a real Echo server against a live PostgreSQL database.
//! Tests fail fast when `DATABASE_URL` / `TEST_DATABASE_URL` is not set.

#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use echo_server::{db, routes, ws};
use ed25519_dalek::{Signer, SigningKey};
use rand::RngCore as _;
use reqwest::Client;
use serde_json::Value;
use tokio::sync::OnceCell;

/// JWT secret used across all integration tests.
pub const TEST_JWT_SECRET: &str = "integration-test-secret";

/// Run migrations exactly once across all tests, even when running in parallel.
static MIGRATIONS: OnceCell<()> = OnceCell::const_new();

/// Spawn a test server and return its base URL (e.g. `http://127.0.0.1:12345`).
pub async fn spawn_server() -> String {
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set for integration tests");

    let pool = db::create_pool(&database_url).await;

    // Ensure migrations run exactly once -- prevents parallel CREATE TABLE races.
    let pool_clone = pool.clone();
    MIGRATIONS
        .get_or_init(|| async {
            db::run_migrations(&pool_clone).await;
        })
        .await;

    let hub = ws::hub::Hub::new();
    let state = Arc::new(routes::AppState {
        pool,
        jwt_secret: TEST_JWT_SECRET.to_string(),
        hub,
        ticket_store: dashmap::DashMap::new(),
        media_tickets: dashmap::DashMap::new(),
    });

    let app = routes::create_router(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("Failed to bind test server");
    let addr = listener.local_addr().expect("Failed to get local addr");

    tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .expect("Test server error");
    });

    format!("http://{addr}")
}

/// Register a new user and return the raw response.
pub async fn register(client: &Client, base: &str, username: &str, password: &str) -> Value {
    let resp = client
        .post(format!("{base}/api/auth/register"))
        .json(&serde_json::json!({
            "username": username,
            "password": password,
        }))
        .send()
        .await
        .expect("register request failed");

    resp.json::<Value>()
        .await
        .expect("register JSON parse failed")
}

/// Register a user and return the raw `reqwest::Response` (for status code assertions).
pub async fn register_raw(
    client: &Client,
    base: &str,
    username: &str,
    password: &str,
) -> reqwest::Response {
    client
        .post(format!("{base}/api/auth/register"))
        .json(&serde_json::json!({
            "username": username,
            "password": password,
        }))
        .send()
        .await
        .expect("register request failed")
}

/// Log in and return `(access_token, user_id)`.
pub async fn login(
    client: &Client,
    base: &str,
    username: &str,
    password: &str,
) -> (String, String) {
    let resp = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({
            "username": username,
            "password": password,
        }))
        .send()
        .await
        .expect("login request failed");

    let body: Value = resp.json().await.expect("login JSON parse failed");
    let token = body["access_token"]
        .as_str()
        .expect("missing access_token")
        .to_string();
    let user_id = body["user_id"]
        .as_str()
        .expect("missing user_id")
        .to_string();
    (token, user_id)
}

/// Log in and return the raw `reqwest::Response` for status code assertions.
pub async fn login_raw(
    client: &Client,
    base: &str,
    username: &str,
    password: &str,
) -> reqwest::Response {
    client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({
            "username": username,
            "password": password,
        }))
        .send()
        .await
        .expect("login request failed")
}

/// Obtain a single-use WebSocket ticket for the given access token.
pub async fn get_ws_ticket(client: &Client, base: &str, token: &str) -> String {
    let resp = client
        .post(format!("{base}/api/auth/ws-ticket"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .expect("ws-ticket request failed");

    let body: Value = resp.json().await.expect("ws-ticket JSON parse failed");
    body["ticket"].as_str().expect("missing ticket").to_string()
}

/// Generate a unique username using a UUID suffix to avoid collisions across parallel tests.
pub fn unique_username(prefix: &str) -> String {
    let suffix = uuid::Uuid::new_v4().simple().to_string();
    format!("{prefix}_{}", &suffix[..8])
}

// ---------------------------------------------------------------------------
// Convenience helpers
// ---------------------------------------------------------------------------

/// Register a new user, log in, and return `(token, user_id, username)`.
pub async fn register_and_login(
    client: &Client,
    base: &str,
    prefix: &str,
) -> (String, String, String) {
    let username = unique_username(prefix);
    register(client, base, &username, "password123").await;
    let (token, user_id) = login(client, base, &username, "password123").await;
    (token, user_id, username)
}

/// Send a contact request from A to B, accept it, then create the DM
/// conversation so callers get back a `conversation_id`.
pub async fn make_contacts(
    client: &Client,
    base: &str,
    token_a: &str,
    token_b: &str,
    user_b_id: &str,
    username_b: &str,
) -> String {
    // A requests B
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {token_a}"))
        .json(&serde_json::json!({ "username": username_b }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "contact request should 201");
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().unwrap().to_string();

    // B accepts
    let resp = client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {token_b}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "accept contact should 200");

    // Create the DM conversation explicitly so we have a conversation_id
    let resp = client
        .post(format!("{base}/api/conversations/dm"))
        .header("Authorization", format!("Bearer {token_a}"))
        .json(&serde_json::json!({ "peer_user_id": user_b_id }))
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    let body: Value = resp.json().await.unwrap_or_else(|e| {
        panic!("make_contacts: create_dm returned status {status}, JSON parse error: {e}");
    });
    body["conversation_id"]
        .as_str()
        .unwrap_or_else(|| {
            panic!("make_contacts: missing conversation_id in response: {body}");
        })
        .to_string()
}

/// Add a user to a group (caller must be owner/admin).
pub async fn add_member_to_group(
    client: &Client,
    base: &str,
    owner_token: &str,
    group_id: &str,
    member_user_id: &str,
) {
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_user_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "add_member_to_group should return 200"
    );
}

// ---------------------------------------------------------------------------
// PreKey bundle helpers
// ---------------------------------------------------------------------------

/// Data returned from `upload_prekey_bundle` for later assertions.
pub struct PreKeyBundleData {
    pub identity_key: Vec<u8>,
    pub signed_prekey: Vec<u8>,
    pub signing_key_bytes: Vec<u8>,
    pub signing_key: SigningKey,
    pub signed_prekey_id: i32,
    pub otp_key_ids: Vec<i32>,
}

/// Upload a valid PreKey bundle and return the raw key material for assertions.
pub async fn upload_prekey_bundle(
    client: &Client,
    base: &str,
    token: &str,
    device_id: i32,
    num_otps: usize,
) -> PreKeyBundleData {
    let mut secret = [0u8; 32];
    rand::rng().fill_bytes(&mut secret);
    let signing_key = SigningKey::from_bytes(&secret);
    let signing_key_pub = signing_key.verifying_key().to_bytes();

    let mut identity_key = vec![0u8; 32];
    rand::rng().fill_bytes(&mut identity_key);

    let mut signed_prekey = vec![0u8; 32];
    rand::rng().fill_bytes(&mut signed_prekey);

    let signature = signing_key.sign(&signed_prekey);

    let signed_prekey_id = 1;
    let mut otps = Vec::new();
    let mut otp_key_ids = Vec::new();
    for i in 0..num_otps {
        let mut otp_key = vec![0u8; 32];
        rand::rng().fill_bytes(&mut otp_key);
        let key_id = (i + 1) as i32;
        otp_key_ids.push(key_id);
        otps.push(serde_json::json!({
            "key_id": key_id,
            "public_key": BASE64.encode(&otp_key),
        }));
    }

    let body = serde_json::json!({
        "identity_key": BASE64.encode(&identity_key),
        "signed_prekey": BASE64.encode(&signed_prekey),
        "signed_prekey_signature": BASE64.encode(signature.to_bytes()),
        "signed_prekey_id": signed_prekey_id,
        "one_time_prekeys": otps,
        "device_id": device_id,
        "signing_key": BASE64.encode(signing_key_pub),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        201,
        "upload_prekey_bundle should return 201"
    );

    PreKeyBundleData {
        identity_key,
        signed_prekey,
        signing_key_bytes: signing_key_pub.to_vec(),
        signing_key,
        signed_prekey_id,
        otp_key_ids,
    }
}
