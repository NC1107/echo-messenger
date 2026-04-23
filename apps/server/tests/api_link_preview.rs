//! Integration tests for the link preview endpoint.
//!
//! Most tests exercise URL validation logic that rejects requests before
//! any network fetch occurs, so they are fully deterministic and do not
//! require external network access.

mod common;

use reqwest::Client;
use serde_json::Value;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// POST /api/link-preview with a Bearer token and a JSON body.
async fn post_link_preview(
    client: &Client,
    base: &str,
    token: &str,
    body: &serde_json::Value,
) -> reqwest::Response {
    client
        .post(format!("{base}/api/link-preview"))
        .header("Authorization", format!("Bearer {token}"))
        .json(body)
        .send()
        .await
        .expect("link-preview request failed")
}

/// POST /api/link-preview without any Authorization header.
async fn post_link_preview_no_auth(
    client: &Client,
    base: &str,
    body: &serde_json::Value,
) -> reqwest::Response {
    client
        .post(format!("{base}/api/link-preview"))
        .json(body)
        .send()
        .await
        .expect("link-preview request failed")
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

#[tokio::test]
async fn request_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = post_link_preview_no_auth(
        &client,
        &base,
        &serde_json::json!({"url": "https://example.com"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Input validation (no network required)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn empty_url_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_empty").await;

    let resp = post_link_preview(&client, &base, &token, &serde_json::json!({"url": ""})).await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(body["error"].as_str().unwrap().contains("http"));
}

#[tokio::test]
async fn missing_url_field_returns_error() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_missing").await;

    let resp = post_link_preview(&client, &base, &token, &serde_json::json!({})).await;

    // Axum's Json<T> extractor returns 422 for missing fields
    let status = resp.status().as_u16();
    assert!(
        status == 422 || status == 400,
        "expected 422 or 400, got {status}"
    );
}

#[tokio::test]
async fn malformed_url_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_malformed").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "not-a-valid-url"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(body["error"].as_str().unwrap().contains("http"));
}

#[tokio::test]
async fn file_scheme_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_file").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "file:///etc/passwd"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(body["error"].as_str().unwrap().contains("http"));
}

#[tokio::test]
async fn ftp_scheme_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_ftp").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "ftp://example.com"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(body["error"].as_str().unwrap().contains("http"));
}

// ---------------------------------------------------------------------------
// SSRF protection — private/reserved IP addresses
// ---------------------------------------------------------------------------

#[tokio::test]
async fn loopback_ip_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_loopback").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "http://127.0.0.1:8080/evil"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    let error = body["error"].as_str().unwrap();
    assert!(
        error.to_lowercase().contains("private"),
        "expected error to mention 'private', got: {error}"
    );
}

#[tokio::test]
async fn private_10_network_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_10net").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "http://10.0.0.1/internal"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    let error = body["error"].as_str().unwrap();
    assert!(
        error.to_lowercase().contains("private"),
        "expected error to mention 'private', got: {error}"
    );
}

#[tokio::test]
async fn private_192_168_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_192").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "http://192.168.1.1/admin"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    let error = body["error"].as_str().unwrap();
    assert!(
        error.to_lowercase().contains("private"),
        "expected error to mention 'private', got: {error}"
    );
}

#[tokio::test]
async fn aws_metadata_endpoint_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_aws").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "http://169.254.169.254/latest/meta-data/"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    let error = body["error"].as_str().unwrap();
    assert!(
        error.to_lowercase().contains("private"),
        "expected error to mention 'private', got: {error}"
    );
}

// ---------------------------------------------------------------------------
// Network-dependent (ignored by default)
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore]
async fn valid_url_returns_preview() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "lp_valid").await;

    let resp = post_link_preview(
        &client,
        &base,
        &token,
        &serde_json::json!({"url": "https://example.com"}),
    )
    .await;

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body.get("title").is_some(),
        "expected response to have a 'title' field, got: {body}"
    );
}
