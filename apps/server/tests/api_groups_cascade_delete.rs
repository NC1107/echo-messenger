//! #785: end-to-end assertion that deleting a group conversation cascades
//! to every dependent row at the database level.
//!
//! Migration `20260515100000_extend_cascade_fks_for_conversation_delete`
//! added `ON DELETE CASCADE` to the last remaining child FK
//! (`media.conversation_id`).  With that change in place, the 9-statement
//! transactional `delete_group_dependents` collapses to a single call to
//! `db::groups::force_delete_conversation`, which issues
//! `DELETE FROM conversations WHERE id = $1`.
//!
//! This test seeds a group with rows in every dependent table:
//!   conversation_members, channels, messages, reactions, mentions,
//!   message_device_contents, message_deliveries, banned_members,
//!   read_receipts, group_keys, group_key_envelopes, media,
//!   pinned_conversations, group_invite_tokens, voice_sessions,
//!   channel_canvas, plus a message that is pinned via the
//!   `messages.pinned_at` column.
//!
//! It then calls `force_delete_conversation` (the same path now used by
//! `cleanup_empty_groups`) and asserts every dependent row is gone.
//! A regression that removes `ON DELETE CASCADE` from any of these FKs
//! will fail this test with a FK-violation error from Postgres.

mod common;

use sqlx::Row;
use uuid::Uuid;

#[tokio::test]
async fn force_delete_conversation_cascades_to_every_child_table() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    let (owner_token, owner_id_str, _owner_username) =
        common::register_and_login(&client, &base, "casc785_own").await;
    let (_member_token, member_id_str, _member_username) =
        common::register_and_login(&client, &base, "casc785_mem").await;

    let group_id_str = common::create_group(&client, &base, &owner_token, "cascade-785").await;
    let group_id = Uuid::parse_str(&group_id_str).expect("group id is a UUID");
    common::add_member_to_group(&client, &base, &owner_token, &group_id_str, &member_id_str).await;

    let owner_id = Uuid::parse_str(&owner_id_str).expect("owner id is a UUID");
    let member_id = Uuid::parse_str(&member_id_str).expect("member id is a UUID");

    let pool = common::test_pool().await;

    // ---- Seed channels + grandchildren ----
    let channel_id: Uuid = sqlx::query_scalar(
        "INSERT INTO channels (conversation_id, name, kind) \
         VALUES ($1, $2, 'text') RETURNING id",
    )
    .bind(group_id)
    .bind(format!("ch-{}", Uuid::new_v4().simple()))
    .fetch_one(&pool)
    .await
    .expect("seed channel");

    let voice_channel_id: Uuid = sqlx::query_scalar(
        "INSERT INTO channels (conversation_id, name, kind) \
         VALUES ($1, $2, 'voice') RETURNING id",
    )
    .bind(group_id)
    .bind(format!("vc-{}", Uuid::new_v4().simple()))
    .fetch_one(&pool)
    .await
    .expect("seed voice channel");

    sqlx::query(
        "INSERT INTO voice_sessions (channel_id, user_id) VALUES ($1, $2) \
         ON CONFLICT DO NOTHING",
    )
    .bind(voice_channel_id)
    .bind(owner_id)
    .execute(&pool)
    .await
    .expect("seed voice_session");

    sqlx::query(
        "INSERT INTO channel_canvas (channel_id, drawing_data, images_data) \
         VALUES ($1, '[]'::jsonb, '[]'::jsonb)",
    )
    .bind(voice_channel_id)
    .execute(&pool)
    .await
    .expect("seed channel_canvas");

    // ---- Seed messages + grandchildren ----
    let message_id: Uuid = sqlx::query_scalar(
        "INSERT INTO messages (conversation_id, sender_id, content, channel_id, pinned_by_id, pinned_at) \
         VALUES ($1, $2, 'hi', $3, $2, NOW()) RETURNING id",
    )
    .bind(group_id)
    .bind(owner_id)
    .bind(channel_id)
    .fetch_one(&pool)
    .await
    .expect("seed message");

    sqlx::query("INSERT INTO reactions (message_id, user_id, emoji) VALUES ($1, $2, '👍')")
        .bind(message_id)
        .bind(member_id)
        .execute(&pool)
        .await
        .expect("seed reaction");

    sqlx::query("INSERT INTO mentions (message_id, mentioned_user_id) VALUES ($1, $2)")
        .bind(message_id)
        .bind(member_id)
        .execute(&pool)
        .await
        .expect("seed mention");

    sqlx::query(
        "INSERT INTO message_device_contents (message_id, recipient_user_id, device_id, content) \
         VALUES ($1, $2, 1, 'ciphertext')",
    )
    .bind(message_id)
    .bind(member_id)
    .execute(&pool)
    .await
    .expect("seed message_device_contents");

    sqlx::query(
        "INSERT INTO message_deliveries (message_id, recipient_user_id, device_id) \
         VALUES ($1, $2, 1)",
    )
    .bind(message_id)
    .bind(member_id)
    .execute(&pool)
    .await
    .expect("seed message_deliveries");

    // ---- Seed read_receipts ----
    sqlx::query(
        "INSERT INTO read_receipts (conversation_id, user_id) VALUES ($1, $2) \
         ON CONFLICT DO NOTHING",
    )
    .bind(group_id)
    .bind(owner_id)
    .execute(&pool)
    .await
    .expect("seed read_receipts");

    // ---- Seed banned_members ----
    // Register a third user so we can ban them without disrupting the active
    // membership rows.
    let (_, ban_target_id_str, _) = common::register_and_login(&client, &base, "casc785_bnd").await;
    let ban_target_id = Uuid::parse_str(&ban_target_id_str).expect("bn id is a UUID");
    sqlx::query(
        "INSERT INTO banned_members (conversation_id, user_id, banned_by) \
         VALUES ($1, $2, $3)",
    )
    .bind(group_id)
    .bind(ban_target_id)
    .bind(owner_id)
    .execute(&pool)
    .await
    .expect("seed banned_members");

    // ---- Seed group_keys + group_key_envelopes ----
    sqlx::query(
        "INSERT INTO group_keys (conversation_id, key_version, encrypted_key, created_by) \
         VALUES ($1, 1, 'placeholder', $2)",
    )
    .bind(group_id)
    .bind(owner_id)
    .execute(&pool)
    .await
    .expect("seed group_keys");

    sqlx::query(
        "INSERT INTO group_key_envelopes \
            (conversation_id, key_version, recipient_user_id, encrypted_key) \
         VALUES ($1, 1, $2, 'envelope-bytes')",
    )
    .bind(group_id)
    .bind(member_id)
    .execute(&pool)
    .await
    .expect("seed group_key_envelopes");

    // ---- Seed media ----
    sqlx::query(
        "INSERT INTO media (uploader_id, filename, mime_type, size_bytes, conversation_id) \
         VALUES ($1, 'pic.png', 'image/png', 42, $2)",
    )
    .bind(owner_id)
    .bind(group_id)
    .execute(&pool)
    .await
    .expect("seed media");

    // ---- Seed pinned_conversations ----
    sqlx::query(
        "INSERT INTO pinned_conversations (user_id, conversation_id) \
         VALUES ($1, $2) ON CONFLICT DO NOTHING",
    )
    .bind(owner_id)
    .bind(group_id)
    .execute(&pool)
    .await
    .expect("seed pinned_conversations");

    // ---- Seed group_invite_tokens ----
    sqlx::query(
        "INSERT INTO group_invite_tokens (token, conversation_id, created_by) \
         VALUES ($1, $2, $3)",
    )
    .bind(Uuid::new_v4().simple().to_string())
    .bind(group_id)
    .bind(owner_id)
    .execute(&pool)
    .await
    .expect("seed group_invite_tokens");

    // ---- Sanity: confirm seeds are present before delete ----
    let pre_messages: i64 = sqlx::query("SELECT COUNT(*) FROM messages WHERE conversation_id = $1")
        .bind(group_id)
        .fetch_one(&pool)
        .await
        .unwrap()
        .get(0);
    assert!(pre_messages >= 1, "expected seeded messages");

    let pre_media: i64 = sqlx::query("SELECT COUNT(*) FROM media WHERE conversation_id = $1")
        .bind(group_id)
        .fetch_one(&pool)
        .await
        .unwrap()
        .get(0);
    assert!(pre_media >= 1, "expected seeded media");

    // ---- Trigger the cascade ----
    echo_server::db::groups::force_delete_conversation(&pool, group_id)
        .await
        .expect(
            "force_delete_conversation should succeed once all child FKs CASCADE \
             -- if this fails the migration is incomplete",
        );

    // ---- Assert every dependent row is gone ----
    // Tables keyed on conversation_id directly.
    let direct_tables = [
        "conversation_members",
        "channels",
        "messages",
        "read_receipts",
        "banned_members",
        "group_keys",
        "group_key_envelopes",
        "media",
        "pinned_conversations",
        "group_invite_tokens",
    ];
    for table in direct_tables {
        let sql = format!("SELECT COUNT(*) FROM {table} WHERE conversation_id = $1");
        let count: i64 = sqlx::query(&sql)
            .bind(group_id)
            .fetch_one(&pool)
            .await
            .unwrap_or_else(|e| panic!("count query for {table} failed: {e}"))
            .get(0);
        assert_eq!(
            count, 0,
            "{table} should cascade-delete with parent conversation (had {count} orphans)"
        );
    }

    // Transitive children via channels.
    let voice_sessions_count: i64 =
        sqlx::query("SELECT COUNT(*) FROM voice_sessions WHERE channel_id = $1")
            .bind(voice_channel_id)
            .fetch_one(&pool)
            .await
            .unwrap()
            .get(0);
    assert_eq!(
        voice_sessions_count, 0,
        "voice_sessions should cascade via channels (had {voice_sessions_count} orphans)"
    );

    let channel_canvas_count: i64 =
        sqlx::query("SELECT COUNT(*) FROM channel_canvas WHERE channel_id = $1")
            .bind(voice_channel_id)
            .fetch_one(&pool)
            .await
            .unwrap()
            .get(0);
    assert_eq!(
        channel_canvas_count, 0,
        "channel_canvas should cascade via channels (had {channel_canvas_count} orphans)"
    );

    // Transitive children via messages.
    let grandchild_tables = [
        ("reactions", "message_id"),
        ("mentions", "message_id"),
        ("message_device_contents", "message_id"),
        ("message_deliveries", "message_id"),
    ];
    for (table, col) in grandchild_tables {
        let sql = format!("SELECT COUNT(*) FROM {table} WHERE {col} = $1");
        let count: i64 = sqlx::query(&sql)
            .bind(message_id)
            .fetch_one(&pool)
            .await
            .unwrap_or_else(|e| panic!("count query for {table} failed: {e}"))
            .get(0);
        assert_eq!(
            count, 0,
            "{table} should cascade-delete with parent message (had {count} orphans)"
        );
    }

    // Finally, the conversation row itself.
    let conv_count: i64 = sqlx::query("SELECT COUNT(*) FROM conversations WHERE id = $1")
        .bind(group_id)
        .fetch_one(&pool)
        .await
        .unwrap()
        .get(0);
    assert_eq!(conv_count, 0, "conversation row should be gone");

    pool.close().await;
}
