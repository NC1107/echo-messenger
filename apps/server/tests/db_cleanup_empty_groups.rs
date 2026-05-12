//! #829: assert `find_empty_group_ids` reaps groups whose only members are
//! soft-removed (tombstones).
//!
//! Pre-fix, `cleanup_empty_groups` checked `NOT IN (SELECT DISTINCT
//! conversation_id FROM conversation_members)` without filtering
//! `is_removed`, so tombstone-only groups looked "non-empty" forever.

mod common;

use sqlx::Executor;
use uuid::Uuid;

#[tokio::test]
async fn find_empty_group_ids_includes_tombstone_only_groups() {
    let base = common::spawn_server().await;
    let client = reqwest::Client::new();

    // Owner + one member, in a fresh group.
    let (owner_token, _owner_id, _owner_username) =
        common::register_and_login(&client, &base, "ceg_own").await;
    let (_member_token, member_id, _member_username) =
        common::register_and_login(&client, &base, "ceg_mem").await;

    let group_id = common::create_group(&client, &base, &owner_token, "TombstoneGroup").await;
    let group_uuid = Uuid::parse_str(&group_id).expect("group id is a UUID");
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id).await;

    // Direct pool for assertion-phase manipulation. The server already ran
    // migrations.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set for integration tests");
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect to test db");

    // Soft-remove every member of the group (owner and member). The group
    // now has rows in `conversation_members` but none with
    // `is_removed = false` -- the classic tombstone-only state.
    pool.execute(
        sqlx::query(
            "UPDATE conversation_members \
             SET is_removed = true, removed_at = now() \
             WHERE conversation_id = $1",
        )
        .bind(group_uuid),
    )
    .await
    .expect("soft-remove all members");

    // `find_empty_group_ids` must surface this group.
    let empty = echo_server::db::groups::find_empty_group_ids(&pool)
        .await
        .expect("find_empty_group_ids ok");
    assert!(
        empty.contains(&group_uuid),
        "tombstone-only group must be reported as empty (got {empty:?})"
    );

    // Sanity: a group with at least one active member must NOT be returned.
    // Use a second group from a fresh owner to avoid contaminating other
    // tests that scan all groups.
    let (other_token, _, _) = common::register_and_login(&client, &base, "ceg_oth").await;
    let active_group_id = common::create_group(&client, &base, &other_token, "ActiveGroup").await;
    let active_group_uuid = Uuid::parse_str(&active_group_id).expect("active id is a UUID");
    let empty_after = echo_server::db::groups::find_empty_group_ids(&pool)
        .await
        .expect("find_empty_group_ids ok");
    assert!(
        !empty_after.contains(&active_group_uuid),
        "group with an active member must NOT be reaped"
    );
}
