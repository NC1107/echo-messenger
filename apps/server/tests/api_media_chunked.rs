//! Integration tests for the resumable / chunked upload pipeline (#556).
//!
//! These exercise the public `POST/PATCH/GET /api/media/upload/...`
//! endpoints end-to-end against a real Postgres + Axum stack spun up by
//! the shared test harness in `tests/common`.  No mocks: every test
//! authenticates a real user, drives a real HTTP client, and asserts on
//! the live DB state where relevant.

mod common;

use reqwest::Client;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

/// Synthetic PNG payload used as the body of the chunked test uploads.
/// Repeats a 1x1 PNG to reach 7 MB so the upload spans two 5 MB chunks
/// (the server-announced `chunk_size`).  The MIME detection in finalize
/// runs against the first 512 bytes only, so the leading PNG magic is
/// the only thing that matters for content-sniff.
const MINIMAL_PNG_HEADER: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
];

fn synthetic_payload(size: usize) -> Vec<u8> {
    let mut v = Vec::with_capacity(size);
    v.extend_from_slice(MINIMAL_PNG_HEADER);
    v.resize(size, 0);
    v
}

async fn init_upload(client: &Client, base: &str, token: &str, total_size: usize) -> (Uuid, i64) {
    let resp = client
        .post(format!("{base}/api/media/upload/init"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&json!({
            "filename": "test.png",
            "mime_type": "image/png",
            "total_size": total_size,
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "init should return 201");
    let body: Value = resp.json().await.unwrap();
    let id = Uuid::parse_str(body["upload_id"].as_str().unwrap()).unwrap();
    let chunk_size = body["chunk_size"].as_i64().unwrap();
    (id, chunk_size)
}

async fn send_chunk(
    client: &Client,
    base: &str,
    token: &str,
    upload_id: Uuid,
    chunk: &[u8],
    start: usize,
    total: usize,
) -> reqwest::Response {
    let end = start + chunk.len() - 1;
    client
        .patch(format!("{base}/api/media/upload/{upload_id}/chunk"))
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Range", format!("bytes {start}-{end}/{total}"))
        .body(chunk.to_vec())
        .send()
        .await
        .unwrap()
}

// ---------------------------------------------------------------------------
// Happy path
// ---------------------------------------------------------------------------

#[tokio::test]
async fn init_creates_pending_session_in_db() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "chunked_init").await;

    let (upload_id, chunk_size) = init_upload(&client, &base, &token, 1024).await;
    assert_eq!(
        chunk_size,
        5 * 1024 * 1024,
        "default chunk_size must be 5MB"
    );

    // GET state should report a pending session at offset 0.
    let resp = client
        .get(format!("{base}/api/media/upload/{upload_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["bytes_received"].as_i64().unwrap(), 0);
    assert_eq!(body["total_size"].as_i64().unwrap(), 1024);
    assert_eq!(body["status"].as_str().unwrap(), "pending");
}

#[tokio::test]
async fn chunks_append_in_order_and_finalize_returns_media_url() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "chunked_happy").await;

    let total = 7 * 1024 * 1024; // spans two chunks at the 5 MB boundary
    let payload = synthetic_payload(total);
    let (upload_id, chunk_size) = init_upload(&client, &base, &token, total).await;

    let chunk_size = chunk_size as usize;
    let first = &payload[..chunk_size];
    let second = &payload[chunk_size..];

    let r1 = send_chunk(&client, &base, &token, upload_id, first, 0, total).await;
    assert_eq!(r1.status().as_u16(), 200, "first chunk should 200");
    let b1: Value = r1.json().await.unwrap();
    assert_eq!(b1["bytes_received"].as_i64().unwrap(), chunk_size as i64);

    let r2 = send_chunk(&client, &base, &token, upload_id, second, chunk_size, total).await;
    assert_eq!(r2.status().as_u16(), 200, "second chunk should 200");
    let b2: Value = r2.json().await.unwrap();
    assert_eq!(b2["bytes_received"].as_i64().unwrap(), total as i64);

    let resp = client
        .post(format!("{base}/api/media/upload/{upload_id}/finalize"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "finalize should return 201");
    let body: Value = resp.json().await.unwrap();
    assert!(!body["id"].as_str().unwrap().is_empty());
    assert!(body["url"].as_str().unwrap().contains("/api/media/"));
}

// ---------------------------------------------------------------------------
// Out-of-order / range-mismatch behaviour
// ---------------------------------------------------------------------------

#[tokio::test]
async fn out_of_order_chunk_returns_416_with_bytes_received() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "chunked_416").await;

    let total = 1024;
    let payload = synthetic_payload(total);
    let (upload_id, _) = init_upload(&client, &base, &token, total).await;

    // Skip the first 100 bytes and try to write from offset 100.
    let resp = send_chunk(
        &client,
        &base,
        &token,
        upload_id,
        &payload[100..200],
        100,
        total,
    )
    .await;
    assert_eq!(resp.status().as_u16(), 416, "range mismatch must be 416");
    let body: Value = resp.json().await.unwrap();
    assert_eq!(
        body["bytes_received"].as_i64().unwrap(),
        0,
        "server should report its real offset so the client can re-sync"
    );
}

#[tokio::test]
async fn malformed_content_range_returns_4xx() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "chunked_bad_range").await;

    let (upload_id, _) = init_upload(&client, &base, &token, 1024).await;

    let resp = client
        .patch(format!("{base}/api/media/upload/{upload_id}/chunk"))
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Range", "not-a-range")
        .body(vec![0u8; 10])
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Finalize state validation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn finalize_rejects_incomplete_session() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "chunked_incomplete").await;

    let total = 1024;
    let (upload_id, _) = init_upload(&client, &base, &token, total).await;

    // Only send half the bytes.
    let payload = synthetic_payload(total);
    let half = &payload[..512];
    let chunk_resp = send_chunk(&client, &base, &token, upload_id, half, 0, total).await;
    assert_eq!(chunk_resp.status().as_u16(), 200);

    let resp = client
        .post(format!("{base}/api/media/upload/{upload_id}/finalize"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "incomplete upload must not finalize"
    );
}

// ---------------------------------------------------------------------------
// Auth / cross-tenant isolation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn chunked_endpoints_reject_unauth() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/media/upload/init"))
        .json(&json!({"filename":"a","mime_type":"image/png","total_size":1}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn other_user_cannot_see_or_chunk_my_session() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (token_a, _, _) = common::register_and_login(&client, &base, "chunked_owner").await;
    let (token_b, _, _) = common::register_and_login(&client, &base, "chunked_other").await;

    let (upload_id, _) = init_upload(&client, &base, &token_a, 1024).await;

    let resp = client
        .get(format!("{base}/api/media/upload/{upload_id}"))
        .header("Authorization", format!("Bearer {token_b}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404, "must look like 404 to others");

    let resp = send_chunk(&client, &base, &token_b, upload_id, &[0u8; 16], 0, 1024).await;
    assert_eq!(resp.status().as_u16(), 404);
}

// ---------------------------------------------------------------------------
// Background cleanup
// ---------------------------------------------------------------------------

#[tokio::test]
async fn cleanup_sweep_aborts_stale_pending_session() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "chunked_sweep").await;

    let (upload_id, _) = init_upload(&client, &base, &token, 1024).await;

    // Run the sweep with a zero-second idle window so the freshly created
    // session is immediately eligible.  Pull a PgPool the same way the
    // harness does so we don't need to expose internals on AppState.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool: PgPool = sqlx::PgPool::connect(&database_url).await.unwrap();

    echo_server::routes::media_chunked::cleanup_stale_uploads(&pool, 0).await;

    let resp = client
        .get(format!("{base}/api/media/upload/{upload_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(
        body["status"].as_str().unwrap(),
        "aborted",
        "sweep should mark the row aborted"
    );
}
