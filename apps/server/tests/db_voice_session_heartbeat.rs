//! VL-3 regression: the stale-voice-session sweep must not evict a
//! participant who is connected but idle. The WebSocket heartbeat calls
//! `touch_user_voice_sessions` every 30s to keep `updated_at` fresh; this
//! test exercises that touch + sweep interaction at the DB layer.

mod common;

use uuid::Uuid;

/// Resolve the auto-seeded voice channel ('lounge', kind='voice') for a
/// freshly created group/conversation.
async fn voice_channel_for(pool: &sqlx::PgPool, conversation_id: Uuid) -> Uuid {
    let (id,): (Uuid,) = sqlx::query_as(
        "SELECT id FROM channels WHERE conversation_id = $1 AND kind = 'voice' LIMIT 1",
    )
    .bind(conversation_id)
    .fetch_one(pool)
    .await
    .expect("group should have a seeded voice channel");
    id
}

async fn insert_stale_session(pool: &sqlx::PgPool, channel_id: Uuid, user_id: Uuid) {
    sqlx::query(
        "INSERT INTO voice_sessions (channel_id, user_id, updated_at)
         VALUES ($1, $2, now() - interval '10 minutes')
         ON CONFLICT (channel_id, user_id)
         DO UPDATE SET updated_at = now() - interval '10 minutes'",
    )
    .bind(channel_id)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert stale voice session");
}

async fn session_exists(pool: &sqlx::PgPool, channel_id: Uuid, user_id: Uuid) -> bool {
    let row: Option<(i32,)> =
        sqlx::query_as("SELECT 1 FROM voice_sessions WHERE channel_id = $1 AND user_id = $2")
            .bind(channel_id)
            .bind(user_id)
            .fetch_optional(pool)
            .await
            .unwrap();
    row.is_some()
}

#[tokio::test]
async fn touch_keeps_connected_idle_session_alive_through_sweep() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    // Fresh user + group so we're isolated from any parallel test.
    let name = common::unique_username("vl3");
    common::register(&client, &base, &name, "password123").await;
    let (token, user_id_str) = common::login(&client, &base, &name, "password123").await;
    let user_id = Uuid::parse_str(&user_id_str).unwrap();
    let group_id = common::create_group(&client, &base, &token, "vl3-group").await;
    let conv_id = Uuid::parse_str(&group_id).unwrap();

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap();
    let pool = echo_server::db::create_pool(&database_url).await;
    let channel_id = voice_channel_for(&pool, conv_id).await;

    // --- Without a touch, a 10-minute-old session is reclaimed by the sweep.
    insert_stale_session(&pool, channel_id, user_id).await;
    let removed = echo_server::db::channels::cleanup_stale_voice_sessions(&pool, 120)
        .await
        .unwrap();
    assert!(
        removed.iter().any(|(_, _, u)| *u == user_id),
        "a stale session must be swept"
    );
    assert!(!session_exists(&pool, channel_id, user_id).await);

    // --- With the heartbeat touch, the same session survives the sweep.
    insert_stale_session(&pool, channel_id, user_id).await;
    echo_server::db::channels::touch_user_voice_sessions(&pool, user_id)
        .await
        .unwrap();
    let removed = echo_server::db::channels::cleanup_stale_voice_sessions(&pool, 120)
        .await
        .unwrap();
    assert!(
        !removed.iter().any(|(_, _, u)| *u == user_id),
        "a freshly-touched session must NOT be swept (VL-3)"
    );
    assert!(
        session_exists(&pool, channel_id, user_id).await,
        "touched session must still exist after sweep (VL-3)"
    );
}
