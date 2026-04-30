//! Integration tests for `GET /api/server-info`.

mod common;

use reqwest::Client;
use serde_json::Value;

#[tokio::test]
async fn server_info_no_auth_required() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/server-info"))
        .send()
        .await
        .expect("server-info request failed");

    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn server_info_returns_stable_uuid() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let body1: Value = client
        .get(format!("{base}/api/server-info"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let body2: Value = client
        .get(format!("{base}/api/server-info"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let id1 = body1["server_id"].as_str().expect("server_id missing");
    let id2 = body2["server_id"].as_str().expect("server_id missing");
    assert_eq!(id1, id2, "server_id must be stable across requests");

    // Sanity-check shape: parses as UUID.
    uuid::Uuid::parse_str(id1).expect("server_id should be a UUID");
}

#[tokio::test]
async fn server_info_includes_registration_flag() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let body: Value = client
        .get(format!("{base}/api/server-info"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert!(body["registration_open"].is_boolean());
    assert_eq!(body["federation_capable"], Value::Bool(false));
    assert!(
        !body["name"].as_str().unwrap_or("").is_empty(),
        "name must be present"
    );
    assert!(
        !body["version"].as_str().unwrap_or("").is_empty(),
        "version must be present"
    );
}
