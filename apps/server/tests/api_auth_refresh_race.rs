//! Integration test for #520: concurrent `/api/auth/refresh` calls with the
//! same refresh token must not both succeed.  Exactly one wins (200) and the
//! other observes the in-progress rotation as theft (401, family revoked).

mod common;

use reqwest::Client;
use serde_json::Value;

#[tokio::test]
async fn concurrent_refresh_with_same_token_only_one_wins() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let username = common::unique_username("race");
    let password = "password123";
    common::register(&client, &base, &username, password).await;

    // Login to obtain a fresh refresh token.
    let resp = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({
            "username": username,
            "password": password,
        }))
        .send()
        .await
        .expect("login failed");
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let refresh_token = body["refresh_token"]
        .as_str()
        .expect("missing refresh_token in login response")
        .to_string();

    // Race two concurrent refresh requests with the same token.
    let base1 = base.clone();
    let token1 = refresh_token.clone();
    let client1 = client.clone();
    let task_a = tokio::spawn(async move {
        let resp = client1
            .post(format!("{base1}/api/auth/refresh"))
            .json(&serde_json::json!({ "refresh_token": token1 }))
            .send()
            .await
            .expect("refresh A request failed");
        let status = resp.status().as_u16();
        let body: Value = resp.json().await.unwrap_or(Value::Null);
        (status, body)
    });

    let base2 = base.clone();
    let token2 = refresh_token.clone();
    let client2 = client.clone();
    let task_b = tokio::spawn(async move {
        let resp = client2
            .post(format!("{base2}/api/auth/refresh"))
            .json(&serde_json::json!({ "refresh_token": token2 }))
            .send()
            .await
            .expect("refresh B request failed");
        let status = resp.status().as_u16();
        let body: Value = resp.json().await.unwrap_or(Value::Null);
        (status, body)
    });

    let (res_a, res_b) = tokio::join!(task_a, task_b);
    let (status_a, body_a) = res_a.expect("task A panicked");
    let (status_b, body_b) = res_b.expect("task B panicked");

    let mut statuses = [status_a, status_b];
    statuses.sort();
    assert_eq!(
        statuses,
        [200, 401],
        "expected exactly one 200 and one 401, got A={status_a} B={status_b} (bodies: {body_a}, {body_b})"
    );

    // The winner's body has the new refresh token; pull it out.
    let winner_body = if status_a == 200 { &body_a } else { &body_b };
    let winner_refresh = winner_body["refresh_token"]
        .as_str()
        .expect("winner missing refresh_token")
        .to_string();

    // Using the winner's new token must now also fail because the loser's
    // 401 path triggered family-revocation as a reuse-detection signal.
    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": winner_refresh }))
        .send()
        .await
        .expect("post-race refresh failed");
    assert_eq!(
        resp.status().as_u16(),
        401,
        "winner's rotated token must be invalidated by family-revoke"
    );
}
