//! #1338 / VL-28: the WebRTC signaling hot path validates sender + target
//! voice presence with a single batched query (`users_in_voice_channel`)
//! instead of one `EXISTS` per user. This test exercises that query at the DB
//! layer: only the seeded participants are reported present, and absent users
//! are excluded.

mod common;

use std::collections::HashSet;
use uuid::Uuid;

/// Resolve the auto-seeded voice channel ('lounge', kind='voice') for a group.
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

async fn join_voice(pool: &sqlx::PgPool, channel_id: Uuid, user_id: Uuid) {
    sqlx::query(
        "INSERT INTO voice_sessions (channel_id, user_id, updated_at)
         VALUES ($1, $2, now())
         ON CONFLICT (channel_id, user_id) DO UPDATE SET updated_at = now()",
    )
    .bind(channel_id)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert voice session");
}

#[tokio::test]
async fn users_in_voice_channel_reports_only_present_users() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    // One real user/group (mirrors the heartbeat test). The "absent" user is
    // just a UUID with no voice session — the query is satisfied purely by the
    // voice_sessions table, so it needn't be a registered account.
    let name = common::unique_username("vpowner");
    let password = common::unique_password();
    common::register(&client, &base, &name, &password).await;
    let (token, owner_id_str) = common::login(&client, &base, &name, &password).await;
    let owner_id = Uuid::parse_str(&owner_id_str).unwrap();
    let group_id = common::create_group(&client, &base, &token, "voice-presence-group").await;
    let conv_id = Uuid::parse_str(&group_id).unwrap();
    let absent_id = Uuid::new_v4();

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap();
    let pool = echo_server::db::create_pool(&database_url).await;
    let channel_id = voice_channel_for(&pool, conv_id).await;

    // Empty channel → nobody present.
    let present = echo_server::db::channels::users_in_voice_channel(
        &pool,
        channel_id,
        &[owner_id, absent_id],
    )
    .await
    .unwrap();
    assert!(present.is_empty(), "no sessions seeded yet → empty set");

    // Owner joins voice; absent_id never does.
    join_voice(&pool, channel_id, owner_id).await;

    let present = echo_server::db::channels::users_in_voice_channel(
        &pool,
        channel_id,
        &[owner_id, absent_id],
    )
    .await
    .unwrap();
    assert_eq!(
        present,
        HashSet::from([owner_id]),
        "only the joined user is reported present; the absent user is excluded"
    );

    // Querying only an absent user returns the empty set.
    let present_absent =
        echo_server::db::channels::users_in_voice_channel(&pool, channel_id, &[absent_id])
            .await
            .unwrap();
    assert!(
        present_absent.is_empty(),
        "querying only an absent user returns the empty set"
    );

    // Presence is scoped to the channel id: a different channel reports nobody.
    let present_other =
        echo_server::db::channels::users_in_voice_channel(&pool, Uuid::new_v4(), &[owner_id])
            .await
            .unwrap();
    assert!(
        present_other.is_empty(),
        "presence is scoped to the channel id"
    );
}
