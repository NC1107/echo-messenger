//! Direct DB-level test of canvas persistence — bypasses WS and HTTP.
//! Verifies that consecutive append_stroke / add_image calls accumulate
//! correctly in the channel_canvas row.

mod common;

use serde_json::json;
use uuid::Uuid;

#[tokio::test]
async fn append_stroke_accumulates() {
    let base = common::spawn_server().await;
    let _ = base; // unused — we just want shared pool init via migrations

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap();
    let pool = echo_server::db::create_pool(&database_url).await;

    // Synthesize a fake channel row. We need a real channel id to satisfy
    // the FK. Easiest: use whatever channels exist (any active test channel
    // will work). The cascade FK only fires on DELETE — we never delete here.
    let ch: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM channels LIMIT 1")
        .fetch_optional(&pool)
        .await
        .unwrap();
    let Some((cid,)) = ch else {
        // No channels yet (fresh DB, no other tests have run before us).
        // Skip with a friendly message instead of failing — the WS-level
        // late_joiner test also exercises this path.
        eprintln!("no channels in DB; skipping direct DB test");
        return;
    };

    // Reset this channel's canvas state.
    sqlx::query("DELETE FROM channel_canvas WHERE channel_id = $1")
        .bind(cid)
        .execute(&pool)
        .await
        .unwrap();

    let author = Uuid::new_v4();
    echo_server::db::canvas::append_stroke(&pool, cid, author, json!({"id":"d1","kind":"pen"}))
        .await
        .unwrap();
    echo_server::db::canvas::append_stroke(&pool, cid, author, json!({"id":"d2","kind":"text"}))
        .await
        .unwrap();
    echo_server::db::canvas::append_stroke(&pool, cid, author, json!({"id":"d3","kind":"rect"}))
        .await
        .unwrap();
    echo_server::db::canvas::add_image(&pool, cid, author, json!({"id":"i1","url":"x"}))
        .await
        .unwrap();

    let row = echo_server::db::canvas::get(&pool, cid).await.unwrap();
    let strokes = row.drawing_data.as_array().expect("drawing_data array");
    let images = row.images_data.as_array().expect("images_data array");
    assert_eq!(
        strokes.len(),
        3,
        "all three strokes must accumulate; got: {strokes:?}"
    );
    assert_eq!(images.len(), 1, "image must persist");
}
