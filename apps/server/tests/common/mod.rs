//! Shared test harness for integration tests.
//!
//! Spins up a real Echo server against a live PostgreSQL database.
//! Tests fail fast when `DATABASE_URL` / `TEST_DATABASE_URL` is not set.

#![allow(dead_code)]

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use echo_server::{db, routes, ws};
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
        ticket_store: Mutex::new(HashMap::new()),
        media_tickets: Mutex::new(HashMap::new()),
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
