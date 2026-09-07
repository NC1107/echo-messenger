//! Direct DB-level test for per-user canvas clear (VL-15 / #1331).
//!
//! Seeds strokes + images authored by two distinct users into one channel
//! canvas, then verifies:
//!   - `clear_user_drawings(A)` removes only A's strokes/images, leaving B's.
//!   - `clear_all` removes everything.
//!   - entries written without an author (legacy rows) survive a scoped clear.
//!
//! Each test creates its own group + lounge voice channel via the API so it
//! owns a unique `channel_id` — no `LIMIT 1` race with the other canvas suites
//! that share the database.

mod common;

use reqwest::Client;
use serde_json::{Value, json};
use uuid::Uuid;

/// Create a fresh group and return its default lounge voice channel id.
async fn fresh_lounge_channel(client: &Client, base: &str) -> Uuid {
    let username = common::unique_username("clrscope");
    let password = common::unique_password();
    common::register(client, base, &username, &password).await;
    let (token, _) = common::login(client, base, &username, &password).await;
    let group_id = common::create_group(client, base, &token, "ClearScopeGroup").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    let channels: Vec<Value> = resp.json().await.unwrap();
    let lounge = channels
        .iter()
        .find(|c| c["name"] == "lounge")
        .expect("default lounge voice channel should exist");
    Uuid::parse_str(lounge["id"].as_str().unwrap()).unwrap()
}

#[tokio::test]
async fn clear_user_drawings_removes_only_that_users_entries() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let cid = fresh_lounge_channel(&client, &base).await;
    let pool = common::test_pool().await;

    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();

    // Alice: 2 strokes + 1 image. Bob: 1 stroke + 1 image.
    echo_server::db::canvas::append_stroke(&pool, cid, alice, json!({"id":"a1","kind":"pen"}))
        .await
        .unwrap();
    echo_server::db::canvas::append_stroke(&pool, cid, alice, json!({"id":"a2","kind":"pen"}))
        .await
        .unwrap();
    echo_server::db::canvas::append_stroke(&pool, cid, bob, json!({"id":"b1","kind":"pen"}))
        .await
        .unwrap();
    echo_server::db::canvas::add_image(&pool, cid, alice, json!({"id":"ai","url":"x"}))
        .await
        .unwrap();
    echo_server::db::canvas::add_image(&pool, cid, bob, json!({"id":"bi","url":"y"}))
        .await
        .unwrap();

    // Inject a legacy entry with no author to prove it is NOT clobbered by a
    // scoped clear (the migration-safe path).
    sqlx::query(
        "UPDATE channel_canvas
         SET drawing_data = drawing_data || jsonb_build_array('{\"id\":\"legacy\",\"kind\":\"pen\"}'::jsonb)
         WHERE channel_id = $1",
    )
    .bind(cid)
    .execute(&pool)
    .await
    .unwrap();

    // Sanity: 4 strokes (a1, a2, b1, legacy) + 2 images.
    let row = echo_server::db::canvas::get(&pool, cid).await.unwrap();
    assert_eq!(row.drawing_data.as_array().unwrap().len(), 4);
    assert_eq!(row.images_data.as_array().unwrap().len(), 2);

    // Clear Alice's only.
    echo_server::db::canvas::clear_user_drawings(&pool, cid, alice)
        .await
        .unwrap();

    let row = echo_server::db::canvas::get(&pool, cid).await.unwrap();
    let stroke_ids: Vec<&str> = row
        .drawing_data
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap())
        .collect();
    let image_ids: Vec<&str> = row
        .images_data
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["id"].as_str().unwrap())
        .collect();

    assert!(!stroke_ids.contains(&"a1"), "a1 should be cleared");
    assert!(!stroke_ids.contains(&"a2"), "a2 should be cleared");
    assert!(stroke_ids.contains(&"b1"), "b1 (bob) must remain");
    assert!(
        stroke_ids.contains(&"legacy"),
        "legacy (no author) must remain"
    );
    assert!(!image_ids.contains(&"ai"), "ai should be cleared");
    assert!(image_ids.contains(&"bi"), "bi (bob) must remain");

    // Clear all removes the rest.
    echo_server::db::canvas::clear_all(&pool, cid)
        .await
        .unwrap();
    let row = echo_server::db::canvas::get(&pool, cid).await.unwrap();
    assert!(row.drawing_data.as_array().unwrap().is_empty());
    assert!(row.images_data.as_array().unwrap().is_empty());
}

#[tokio::test]
async fn append_stamps_author_into_persisted_json() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let cid = fresh_lounge_channel(&client, &base).await;
    let pool = common::test_pool().await;

    let author = Uuid::new_v4();
    echo_server::db::canvas::append_stroke(&pool, cid, author, json!({"id":"s1","kind":"pen"}))
        .await
        .unwrap();

    let row = echo_server::db::canvas::get(&pool, cid).await.unwrap();
    let stroke = &row.drawing_data.as_array().unwrap()[0];
    assert_eq!(
        stroke["from_user_id"].as_str().unwrap(),
        author.to_string(),
        "stroke must carry the author id for scoped clears"
    );
}
