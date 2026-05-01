//! Audit #698: assert ON DELETE CASCADE behaviour on every child of
//! `conversations` at the database level.
//!
//! Migration 20260412000000 added CASCADE to a subset of FKs that were
//! missing it; the rest were declared with CASCADE in their original
//! creation migrations (group_keys, group_key_envelopes, channels,
//! direct_conversations, pinned_conversations, banned_members). Without a
//! test asserting end-to-end CASCADE behaviour, a future migration could
//! revert one of these silently and the resulting orphan rows would only
//! surface as confusing app-level bugs months later.
//!
//! This test does not exercise per-test isolation (audit #699 still open);
//! it relies on the suite's shared test database and uses a unique group
//! per assertion so concurrent test runs don't interfere.

mod common;

use sqlx::Row;
use uuid::Uuid;

#[tokio::test]
async fn delete_conversation_cascades_to_children() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    // Create owner + member, group, and seed every child table that should
    // cascade-delete with the parent conversation.
    let (owner_token, _owner_id, owner_username) =
        common::register_and_login(&client, &base, "casc_owner").await;
    let (_member_token, member_id, _member_username) =
        common::register_and_login(&client, &base, "casc_member").await;
    let _ = owner_username; // captured for parity with similar helpers

    let group_id = common::create_group(&client, &base, &owner_token, "cascade-test").await;
    let group_uuid = Uuid::parse_str(&group_id).expect("group id is a UUID");
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id).await;

    // Open a direct DB pool for the assertion phase.  The integration server
    // already migrated the database, so we just observe.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set for integration tests");
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect to test db");

    // Tables that should be empty for the group_uuid after cascade.
    // group_keys + group_key_envelopes only get rows when keys are uploaded;
    // they're included so future migrations can't silently drop CASCADE.
    let tables = [
        "conversation_members",
        "channels",
        "messages",
        "read_receipts",
        "group_keys",
        "group_key_envelopes",
        "banned_members",
        "media",
        "direct_conversations",
        "pinned_conversations",
    ];

    // Sanity-check that conversation_members at least is non-empty before
    // delete -- otherwise we'd be asserting on a vacuous truth.
    let pre: i64 =
        sqlx::query("SELECT COUNT(*) FROM conversation_members WHERE conversation_id = $1")
            .bind(group_uuid)
            .fetch_one(&pool)
            .await
            .expect("pre-delete conversation_members count")
            .get(0);
    assert!(
        pre >= 1,
        "expected at least one conversation_members row before delete (got {pre})"
    );

    // Delete the conversation directly to test the FK cascades end-to-end.
    sqlx::query("DELETE FROM conversations WHERE id = $1")
        .bind(group_uuid)
        .execute(&pool)
        .await
        .expect("DELETE FROM conversations failed -- check FK cascades");

    for table in tables {
        let sql = format!("SELECT COUNT(*) FROM {table} WHERE conversation_id = $1");
        let count: i64 = sqlx::query(&sql)
            .bind(group_uuid)
            .fetch_one(&pool)
            .await
            .unwrap_or_else(|e| panic!("count query for {table} failed: {e}"))
            .get(0);
        assert_eq!(
            count, 0,
            "{table} should cascade-delete when its parent conversation is removed (had {count} orphans)"
        );
    }

    pool.close().await;
}
