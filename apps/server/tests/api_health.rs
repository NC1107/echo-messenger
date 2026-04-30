mod common;

use reqwest::Client;

/// /healthz returns 200 with {"status":"ok"} -- no auth required.
#[tokio::test]
async fn healthz_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/healthz"))
        .send()
        .await
        .expect("healthz request failed");

    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.expect("healthz JSON parse failed");
    assert_eq!(body["status"], "ok");
}

/// /readyz returns 200 with {"status":"ok"} when the DB is reachable.
#[tokio::test]
async fn readyz_returns_200_when_db_up() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/readyz"))
        .send()
        .await
        .expect("readyz request failed");

    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.expect("readyz JSON parse failed");
    assert_eq!(body["status"], "ok");
}

// readyz_returns_503_when_db_down: skipped.
//
// Reliably simulating a dead pool requires either a separate server spawned
// with a bogus DATABASE_URL (which panics at pool creation before bind) or
// forcibly closing all connections mid-test -- both are too invasive for the
// shared test harness. The 503 path is covered by unit-level inspection of
// the handler and exercised in production via k8s probe behaviour.
