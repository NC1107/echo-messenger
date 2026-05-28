//! Integration tests for `GET /api/metrics` (#1179).

mod common;

use reqwest::Client;

const TEST_TOKEN: &str = "integration-metrics-test-token";

/// Without `METRICS_TOKEN` the endpoint returns 503 with "metrics disabled".
#[tokio::test]
async fn metrics_503_when_token_unset() {
    let base = common::spawn_server_with_metrics_token(None).await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/metrics"))
        .send()
        .await
        .expect("metrics request failed");

    assert_eq!(
        resp.status().as_u16(),
        503,
        "expected 503 when metrics_token is None"
    );
    let body = resp.text().await.expect("body read failed");
    assert!(
        body.contains("metrics disabled"),
        "expected 'metrics disabled' body, got: {body}"
    );
}

/// With a configured token, a wrong bearer returns 401.
#[tokio::test]
async fn metrics_401_on_wrong_token() {
    let base = common::spawn_server_with_metrics_token(Some(TEST_TOKEN)).await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/metrics"))
        .header("Authorization", "Bearer definitely-wrong")
        .send()
        .await
        .expect("metrics request failed");

    assert_eq!(
        resp.status().as_u16(),
        401,
        "expected 401 on wrong bearer token"
    );
}

/// With the correct token the endpoint returns 200 and valid Prometheus text.
#[tokio::test]
async fn metrics_200_with_correct_token() {
    let base = common::spawn_server_with_metrics_token(Some(TEST_TOKEN)).await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/metrics"))
        .header("Authorization", format!("Bearer {TEST_TOKEN}"))
        .send()
        .await
        .expect("metrics request failed");

    assert_eq!(
        resp.status().as_u16(),
        200,
        "expected 200 with correct token"
    );

    let ct = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        ct.contains("text/plain"),
        "expected text/plain content-type, got: {ct}"
    );

    let body = resp.text().await.expect("body read failed");

    // Must contain at least one # HELP line.
    assert!(
        body.contains("# HELP"),
        "expected Prometheus HELP comment in body"
    );

    // All four expected metric families must be present.
    assert!(
        body.contains("echo_ws_connections"),
        "missing echo_ws_connections"
    );
    assert!(
        body.contains("echo_messages_per_second"),
        "missing echo_messages_per_second"
    );
    assert!(
        body.contains("echo_failed_logins_total"),
        "missing echo_failed_logins_total"
    );
    assert!(
        body.contains("echo_voice_tokens_issued_total"),
        "missing echo_voice_tokens_issued_total"
    );
}

/// Without an Authorization header the endpoint returns 401 (not 503 — token is set).
#[tokio::test]
async fn metrics_401_when_no_auth_header() {
    let base = common::spawn_server_with_metrics_token(Some(TEST_TOKEN)).await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/metrics"))
        .send()
        .await
        .expect("metrics request failed");

    assert_eq!(
        resp.status().as_u16(),
        401,
        "expected 401 when Authorization header is absent and token is configured"
    );
}
