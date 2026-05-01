//! Shared test harness for integration tests.
//!
//! Spins up a real Echo server against a live PostgreSQL database.
//! Tests fail fast when `DATABASE_URL` / `TEST_DATABASE_URL` is not set.

#![allow(dead_code)]

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use echo_server::{db, routes, ws};
use ed25519_dalek::{Signer, SigningKey};
use reqwest::Client;
use serde_json::Value;
use tokio::sync::OnceCell;

/// JWT secret used across all integration tests.
pub const TEST_JWT_SECRET: &str = "integration-test-secret";

/// Run migrations exactly once across all tests, even when running in parallel.
static MIGRATIONS: OnceCell<()> = OnceCell::const_new();

/// Spawn a test server and return its base URL (e.g. `http://127.0.0.1:12345`).
pub async fn spawn_server() -> String {
    spawn_server_inner(vec![]).await
}

/// Spawn a test server that treats `trusted_proxies` as trusted reverse proxies
/// for IP extraction in rate-limit middleware.
pub async fn spawn_server_with_trusted_proxies(trusted_proxies: Vec<IpAddr>) -> String {
    spawn_server_inner(trusted_proxies).await
}

async fn spawn_server_inner(trusted_proxies: Vec<IpAddr>) -> String {
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

    let app = routes::create_router(state, trusted_proxies);

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

/// Obtain a WebSocket ticket bound to a specific device id.  Used by
/// multi-device fanout / replay tests (#557).
pub async fn get_ws_ticket_for_device(
    client: &Client,
    base: &str,
    token: &str,
    device_id: i32,
) -> String {
    let resp = client
        .post(format!("{base}/api/auth/ws-ticket"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "device_id": device_id }))
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
// WebSocket helpers (audit #695)
// ---------------------------------------------------------------------------
//
// 32 integration tests sat on a `tokio::time::sleep(200ms); drain_pending()`
// pattern to wait for chatter to arrive before reading a specific frame.
// Under CI load (cargo running 250+ tests in parallel) the 200ms became
// brittle and tests flaked intermittently. These helpers replace the
// wall-clock waits with predicate-based reads bounded by an explicit
// timeout, mirroring the pattern that already worked in
// `api_messages_reply_scope.rs::wait_for_event`.

/// WebSocket stream type used by the integration suite.
pub type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Read frames until one whose `type` field is in `wanted` arrives, or fail
/// after `Duration::from_secs(5)`.  Skips presence/typing/echo chatter the
/// caller didn't ask about.
///
/// Use this in place of `tokio::time::sleep(200ms); drain_pending()` when
/// you know the next interesting frame's type.
pub async fn recv_until_event(ws: &mut WsStream, wanted: &[&str]) -> serde_json::Value {
    use futures_util::StreamExt;
    use std::time::Duration;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let next = tokio::time::timeout_at(deadline, ws.next())
            .await
            .expect("timed out waiting for event");
        let frame = next.expect("WS stream closed").expect("WS error");
        if let tokio_tungstenite::tungstenite::Message::Text(text) = frame
            && let Ok(v) = serde_json::from_str::<serde_json::Value>(&text)
            && let Some(t) = v["type"].as_str()
            && wanted.contains(&t)
        {
            return v;
        }
    }
}

/// Read every immediately-available frame and discard.  Returns once 150ms
/// pass without a new frame.  Use after a write to swallow chatter when no
/// specific reply is expected.
///
/// Prefer `recv_until_event` when you know the expected event type --
/// `drain_pending` accepts the lossy "best effort" model that the audit
/// flagged as flaky, but kept here as an escape hatch for tests where the
/// next interesting frame depends on inputs the test deliberately doesn't
/// know.
pub async fn drain_pending(ws: &mut WsStream) {
    use futures_util::StreamExt;
    use std::time::Duration;
    while let Ok(Some(Ok(_))) = tokio::time::timeout(Duration::from_millis(150), ws.next()).await {}
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

/// Create a group and return its id.
pub async fn create_group(client: &Client, base: &str, token: &str, name: &str) -> String {
    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        201,
        "create_group should return 201"
    );
    let body: Value = resp.json().await.unwrap();
    body["id"].as_str().unwrap().to_string()
}

// ---------------------------------------------------------------------------
// Ciphertext helpers
// ---------------------------------------------------------------------------

/// Build a base64-encoded payload that is shaped like an Echo wire frame
/// so it passes the server's ciphertext-shape gate (#591). The bytes are
/// not a real session frame — they only carry the magic prefix the server
/// validates. The optional `tag` is appended verbatim so different test
/// cases can distinguish payloads (e.g. "alice", "bob_d11") in assertions.
pub fn dummy_ciphertext(tag: &str) -> String {
    let mut bytes = vec![0xEC, 0x01];
    bytes.extend_from_slice(tag.as_bytes());
    BASE64.encode(&bytes)
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
    let secret = rand::random::<[u8; 32]>();
    let signing_key = SigningKey::from_bytes(&secret);
    let signing_key_pub = signing_key.verifying_key().to_bytes();

    let identity_key = rand::random::<[u8; 32]>().to_vec();
    let signed_prekey = rand::random::<[u8; 32]>().to_vec();

    let signature = signing_key.sign(&signed_prekey);

    let signed_prekey_id = 1;
    let mut otps = Vec::new();
    let mut otp_key_ids = Vec::new();
    for i in 0..num_otps {
        let otp_key = rand::random::<[u8; 32]>().to_vec();
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

/// Upload an additional device bundle reusing the identity key from a previous upload.
pub async fn upload_additional_device(
    client: &Client,
    base: &str,
    token: &str,
    bundle0: &PreKeyBundleData,
    device_id: i32,
) {
    let signed_prekey = rand::random::<[u8; 32]>().to_vec();
    let signature = bundle0.signing_key.sign(&signed_prekey);

    let body = serde_json::json!({
        "identity_key": BASE64.encode(&bundle0.identity_key),
        "signed_prekey": BASE64.encode(&signed_prekey),
        "signed_prekey_signature": BASE64.encode(signature.to_bytes()),
        "signed_prekey_id": 2,
        "one_time_prekeys": [],
        "device_id": device_id,
        "signing_key": BASE64.encode(&bundle0.signing_key_bytes),
    });
    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
}
