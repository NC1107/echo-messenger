//! Concurrency regression for the canvas row-count cap.
//!
//! `append_stroke` / `add_image` cap the per-channel JSONB array at
//! [`MAX_STROKES`] / [`MAX_IMAGES`]. The cap used to be a TOCTOU race: a
//! standalone `SELECT jsonb_array_length(...)` count-check followed by a
//! separate `INSERT`. Two appends firing at length `MAX-1` both read `MAX-1`,
//! both pass the `< MAX` check, and both insert — overshooting the cap by one.
//!
//! The fix reads the length under `SELECT ... FOR UPDATE` inside the same
//! transaction as the insert, serializing concurrent appends on the row. This
//! test seeds a canvas at exactly `MAX-1`, fires two appends concurrently with
//! distinct ids, and asserts that exactly one succeeds and the array lands on
//! `MAX` — not `MAX+1`.

mod common;

use reqwest::Client;
use serde_json::{Value, json};
use uuid::Uuid;

use echo_server::db::canvas::{self, CanvasCapError, MAX_IMAGES, MAX_STROKES};

/// Create a fresh group and return its default lounge voice channel id, so this
/// test owns a unique `channel_id` and never races the other canvas suites that
/// share the database.
async fn fresh_lounge_channel(client: &Client, base: &str) -> Uuid {
    let username = common::unique_username("caprace");
    let password = common::unique_password();
    common::register(client, base, &username, &password).await;
    let (token, _) = common::login(client, base, &username, &password).await;
    let group_id = common::create_group(client, base, &token, "CapRaceGroup").await;

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

/// Seed `channel_canvas.<column>` with `count` distinct objects in one shot.
async fn seed_array(pool: &sqlx::PgPool, channel_id: Uuid, column: &str, count: i32) {
    // `column` is a hard-coded literal at the only two call sites below, never
    // user input — safe to interpolate into the statement.
    let (draw, img) = if column == "drawing_data" {
        ("seeded.arr", "'[]'::jsonb")
    } else {
        ("'[]'::jsonb", "seeded.arr")
    };
    let sql = format!(
        "INSERT INTO channel_canvas (channel_id, drawing_data, images_data)
         SELECT $1, {draw}, {img}
         FROM (
           SELECT jsonb_agg(jsonb_build_object('id', 'seed-' || g)) AS arr
           FROM generate_series(1, $2) g
         ) seeded
         ON CONFLICT (channel_id) DO UPDATE SET {column} = EXCLUDED.{column}"
    );
    sqlx::query(&sql)
        .bind(channel_id)
        .bind(count)
        .execute(pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn concurrent_appends_at_cap_never_overshoot_strokes() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let cid = fresh_lounge_channel(&client, &base).await;
    let pool = common::test_pool().await;

    // One short of the cap: a single append fits, a second must be rejected.
    let seed_count = (MAX_STROKES - 1) as i32;
    seed_array(&pool, cid, "drawing_data", seed_count).await;

    let author = Uuid::new_v4();
    let (r1, r2) = tokio::join!(
        canvas::append_stroke(&pool, cid, author, json!({"id": "race-1", "kind": "pen"})),
        canvas::append_stroke(&pool, cid, author, json!({"id": "race-2", "kind": "pen"})),
    );

    let oks = [&r1, &r2].iter().filter(|r| r.is_ok()).count();
    assert_eq!(
        oks, 1,
        "exactly one concurrent append must win: r1={r1:?} r2={r2:?}"
    );
    let cap_rejected = [&r1, &r2]
        .iter()
        .filter(|r| matches!(r, Err(CanvasCapError::CapReached)))
        .count();
    assert_eq!(
        cap_rejected, 1,
        "the loser must be rejected with CapReached"
    );

    let row = canvas::get(&pool, cid).await.unwrap();
    let len = row.drawing_data.as_array().unwrap().len();
    assert_eq!(
        len, MAX_STROKES as usize,
        "array must land exactly on the cap, never overshoot it"
    );
}

#[tokio::test]
async fn concurrent_appends_at_cap_never_overshoot_images() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let cid = fresh_lounge_channel(&client, &base).await;
    let pool = common::test_pool().await;

    let seed_count = (MAX_IMAGES - 1) as i32;
    seed_array(&pool, cid, "images_data", seed_count).await;

    let author = Uuid::new_v4();
    let (r1, r2) = tokio::join!(
        canvas::add_image(&pool, cid, author, json!({"id": "img-1", "url": "x"})),
        canvas::add_image(&pool, cid, author, json!({"id": "img-2", "url": "y"})),
    );

    let oks = [&r1, &r2].iter().filter(|r| r.is_ok()).count();
    assert_eq!(
        oks, 1,
        "exactly one concurrent add_image must win: r1={r1:?} r2={r2:?}"
    );

    let row = canvas::get(&pool, cid).await.unwrap();
    let len = row.images_data.as_array().unwrap().len();
    assert_eq!(
        len, MAX_IMAGES as usize,
        "images array must land exactly on the cap"
    );
}
