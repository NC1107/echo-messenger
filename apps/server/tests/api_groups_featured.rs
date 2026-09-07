//! `GET /api/groups/featured` — the optional welcome group.
//!
//! When `WELCOME_GROUP_ID` is unset (the default in CI and in tests) the
//! endpoint must degrade silently to `204 No Content` rather than erroring,
//! so a server with no configured welcome group is a non-event for clients.
//! The populated path (env pointing at a real public group) is exercised
//! manually; mutating process-global env in a parallel test binary is racy
//! and not worth the flakiness here.

mod common;

use common::{register_and_login, spawn_server};
use reqwest::Client;

#[tokio::test]
async fn featured_group_returns_204_when_unconfigured() {
    let base = spawn_server().await;
    let client = Client::new();
    let (token, _, _) = register_and_login(&client, &base, "featured_none").await;

    let resp = client
        .get(format!("{base}/api/groups/featured"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 204);
}

#[tokio::test]
async fn featured_group_requires_auth() {
    let base = spawn_server().await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/groups/featured"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}
