//! Integration tests for `GET /api/search` (universal search), focused on the
//! security-critical scoping the route MUST enforce (#1e). Universal search
//! spans messages/contacts/groups in one response; a scoping bug would leak
//! messages from conversations the caller isn't in, surface soft-deleted
//! content, or list groups they aren't a member of.
//!
//! Covered:
//!  - message results are scoped to the caller's conversations (no cross-
//!    conversation leak)
//!  - soft-deleted messages are excluded
//!  - group results are scoped to groups the caller is a member of
//!  - empty query → 400; missing auth → 401

mod common;

use reqwest::Client;
use uuid::Uuid;

/// Resolve the auto-seeded text channel for a group's conversation.
async fn text_channel_for(pool: &sqlx::PgPool, conversation_id: Uuid) -> Uuid {
    sqlx::query_scalar(
        "SELECT id FROM channels WHERE conversation_id = $1 AND kind = 'text' LIMIT 1",
    )
    .bind(conversation_id)
    .fetch_one(pool)
    .await
    .expect("group should have a seeded text channel")
}

async fn seed_message(pool: &sqlx::PgPool, conv: Uuid, channel: Uuid, sender: Uuid, content: &str) {
    sqlx::query(
        "INSERT INTO messages (conversation_id, sender_id, content, channel_id) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(conv)
    .bind(sender)
    .bind(content)
    .bind(channel)
    .execute(pool)
    .await
    .expect("seed message");
}

async fn search(client: &Client, base: &str, token: &str, q: &str) -> serde_json::Value {
    let resp = client
        .get(format!("{base}/api/search?q={q}"))
        .bearer_auth(token)
        .send()
        .await
        .expect("search request");
    assert_eq!(
        resp.status().as_u16(),
        200,
        "search should 200 for a member"
    );
    resp.json().await.expect("search json")
}

fn contents(resp: &serde_json::Value) -> Vec<String> {
    resp["messages"]
        .as_array()
        .expect("messages array")
        .iter()
        .map(|m| m["content"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[tokio::test]
async fn search_message_results_are_scoped_to_caller_conversations() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (searcher_token, searcher_id_s, _) =
        common::register_and_login(&client, &base, "srch_me").await;
    let (outsider_token, outsider_id_s, _) =
        common::register_and_login(&client, &base, "srch_out").await;
    let searcher_id = Uuid::parse_str(&searcher_id_s).unwrap();
    let outsider_id = Uuid::parse_str(&outsider_id_s).unwrap();

    // Group A: searcher is the owner/member. Group B: owned by the outsider —
    // the searcher is NOT a member.
    let group_a = Uuid::parse_str(
        &common::create_group(&client, &base, &searcher_token, "qsg Alpha visible").await,
    )
    .unwrap();
    let group_b = Uuid::parse_str(
        &common::create_group(&client, &base, &outsider_token, "qsg Beta hidden").await,
    )
    .unwrap();

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap();
    let pool = echo_server::db::create_pool(&database_url).await;
    let chan_a = text_channel_for(&pool, group_a).await;
    let chan_b = text_channel_for(&pool, group_b).await;

    // A unique token only these three messages contain.
    seed_message(
        &pool,
        group_a,
        chan_a,
        searcher_id,
        "zmsgneedle visible in A",
    )
    .await;
    seed_message(
        &pool,
        group_b,
        chan_b,
        outsider_id,
        "zmsgneedle hidden in B",
    )
    .await;
    // A soft-deleted message in A — must never surface.
    sqlx::query(
        "INSERT INTO messages (conversation_id, sender_id, content, channel_id, deleted_at) \
         VALUES ($1, $2, 'zmsgneedle deleted in A', $3, now())",
    )
    .bind(group_a)
    .bind(searcher_id)
    .bind(chan_a)
    .execute(&pool)
    .await
    .expect("seed soft-deleted message");

    let resp = search(&client, &base, &searcher_token, "zmsgneedle").await;
    let found = contents(&resp);

    assert!(
        found.iter().any(|c| c.contains("visible in A")),
        "searcher must see their own conversation's message; got {found:?}"
    );
    assert!(
        !found.iter().any(|c| c.contains("hidden in B")),
        "MESSAGE LEAK: searcher must NOT see a message from a conversation they're not in; got {found:?}"
    );
    assert!(
        !found.iter().any(|c| c.contains("deleted in A")),
        "soft-deleted message must be excluded from search; got {found:?}"
    );
}

#[tokio::test]
async fn search_group_results_are_scoped_to_member_groups() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (searcher_token, _, _) = common::register_and_login(&client, &base, "gsrch_me").await;
    let (outsider_token, _, _) = common::register_and_login(&client, &base, "gsrch_out").await;

    // Both titles share the search token; only the member one should match.
    common::create_group(&client, &base, &searcher_token, "ztitletoken mine").await;
    common::create_group(&client, &base, &outsider_token, "ztitletoken theirs").await;

    let resp = search(&client, &base, &searcher_token, "ztitletoken").await;
    let titles: Vec<String> = resp["groups"]
        .as_array()
        .expect("groups array")
        .iter()
        .map(|g| g["title"].as_str().unwrap_or_default().to_string())
        .collect();

    assert!(
        titles.iter().any(|t| t.contains("mine")),
        "searcher must see a group they're a member of; got {titles:?}"
    );
    assert!(
        !titles.iter().any(|t| t.contains("theirs")),
        "GROUP LEAK: searcher must NOT see a group they're not a member of; got {titles:?}"
    );
}

#[tokio::test]
async fn search_empty_query_is_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "srch_empty").await;

    let resp = client
        .get(format!("{base}/api/search?q=%20%20%20")) // whitespace trims to empty
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400, "empty/blank query must be 400");
}

#[tokio::test]
async fn search_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let resp = client
        .get(format!("{base}/api/search?q=anything"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        401,
        "unauthenticated search must be 401"
    );
}
