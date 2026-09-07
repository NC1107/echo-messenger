//! VL-24 regression: removing a member from a group must drop their
//! server-side voice presence immediately, not wait for the 60s stale-session
//! sweep. A user kicked while in the lounge should no longer count toward the
//! channel or appear to remaining members.

mod common;

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

async fn insert_session(pool: &sqlx::PgPool, channel_id: Uuid, user_id: Uuid) {
    sqlx::query(
        "INSERT INTO voice_sessions (channel_id, user_id)
         VALUES ($1, $2)
         ON CONFLICT (channel_id, user_id) DO UPDATE SET updated_at = now()",
    )
    .bind(channel_id)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("insert voice session");
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
async fn kicking_member_drops_their_voice_session() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    let owner_name = common::unique_username("evict_owner");
    let member_name = common::unique_username("evict_member");
    let password = common::unique_password();
    common::register(&client, &base, &owner_name, &password).await;
    common::register(&client, &base, &member_name, &password).await;
    let (owner_token, _) = common::login(&client, &base, &owner_name, &password).await;
    let (_, member_id_str) = common::login(&client, &base, &member_name, &password).await;
    let member_id = Uuid::parse_str(&member_id_str).unwrap();

    let group_id = common::create_group(&client, &base, &owner_token, "evict-group").await;
    let conv_id = Uuid::parse_str(&group_id).unwrap();
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id_str).await;

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap();
    let pool = echo_server::db::create_pool(&database_url).await;
    let channel_id = voice_channel_for(&pool, conv_id).await;

    // Member is in the lounge.
    insert_session(&pool, channel_id, member_id).await;
    assert!(
        session_exists(&pool, channel_id, member_id).await,
        "precondition: member has an active voice session"
    );

    // Owner kicks the member.
    let resp = client
        .delete(format!(
            "{base}/api/groups/{group_id}/members/{member_id_str}"
        ))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "kick should succeed");

    // VL-24: their voice presence is gone immediately, without the sweep.
    assert!(
        !session_exists(&pool, channel_id, member_id).await,
        "kicked member's voice session must be removed"
    );
}

#[tokio::test]
async fn leaving_group_drops_own_voice_session() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    let owner_name = common::unique_username("leave_owner");
    let member_name = common::unique_username("leave_member");
    let password = common::unique_password();
    common::register(&client, &base, &owner_name, &password).await;
    common::register(&client, &base, &member_name, &password).await;
    let (owner_token, _) = common::login(&client, &base, &owner_name, &password).await;
    let (member_token, member_id_str) =
        common::login(&client, &base, &member_name, &password).await;
    let member_id = Uuid::parse_str(&member_id_str).unwrap();

    let group_id = common::create_group(&client, &base, &owner_token, "leave-group").await;
    let conv_id = Uuid::parse_str(&group_id).unwrap();
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id_str).await;

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap();
    let pool = echo_server::db::create_pool(&database_url).await;
    let channel_id = voice_channel_for(&pool, conv_id).await;

    insert_session(&pool, channel_id, member_id).await;
    assert!(session_exists(&pool, channel_id, member_id).await);

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/leave"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "leave should succeed");

    assert!(
        !session_exists(&pool, channel_id, member_id).await,
        "leaver's voice session must be removed"
    );
}
