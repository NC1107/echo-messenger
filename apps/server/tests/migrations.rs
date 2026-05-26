//! Audit #699 (partial): exercise the full migration sequence against a
//! freshly created schema, asserting each migration succeeds.
//!
//! The rest of the integration suite shares a single long-lived database
//! (with `OnceCell<MIGRATIONS>` ensuring a one-shot apply per process), so
//! a migration that breaks on an empty schema is invisible until a fresh
//! production deploy. This test isolates that path.
//!
//! Approach: create a unique temporary schema in the existing test database
//! (no CREATE DATABASE permission needed), set `search_path` so all tables
//! land inside it, run `sqlx::migrate!` against a pool pinned to that
//! schema, then drop the schema on teardown.
//!
//! NOTE: this exercises schema-creation idempotency. Per-test row-state
//! isolation across the rest of the suite is handled by the `unique_username`
//! convention documented in `common/mod.rs` (see #699).

use sqlx::Connection;
use sqlx::Executor;
use sqlx::postgres::PgConnection;
use uuid::Uuid;

/// Build a connection string with the same parameters as `TEST_DATABASE_URL`
/// but `?options=-csearch_path%3D<schema>` appended so all queries scope
/// to the fresh schema.
fn url_with_search_path(base: &str, schema: &str) -> String {
    let separator = if base.contains('?') { '&' } else { '?' };
    // %3D is "=", %2C is ","; sqlx forwards the options to libpq verbatim.
    format!("{base}{separator}options=-csearch_path%3D{schema}")
}

#[tokio::test]
async fn migrations_apply_cleanly_to_empty_schema() {
    let database_url =
        match std::env::var("TEST_DATABASE_URL").or_else(|_| std::env::var("DATABASE_URL")) {
            Ok(url) => url,
            Err(_) => {
                eprintln!(
                    "skipping: TEST_DATABASE_URL or DATABASE_URL must be set for integration tests"
                );
                return;
            }
        };

    let schema = format!("test_migrations_{}", Uuid::new_v4().simple());

    // Open a single admin connection on the default search path to create +
    // (later) drop the test schema.  Held for the duration of the test so
    // the schema can be dropped even if the migration step panics.
    let mut admin = PgConnection::connect(&database_url)
        .await
        .expect("connect for schema setup");
    admin
        .execute(format!(r#"CREATE SCHEMA "{schema}""#).as_str())
        .await
        .expect("CREATE SCHEMA failed");

    // Run the migration in a separate scope so we can drop the schema
    // unconditionally afterwards. `catch_unwind` would be safer in a real
    // suite, but for a single-test smoke check we accept the leak risk on
    // panic and drop the schema in the success path.
    let result = std::panic::AssertUnwindSafe(run_migrations_into_schema(&database_url, &schema));
    use futures_util::FutureExt;
    let migration_outcome = result.catch_unwind().await;

    // Always drop the schema, regardless of success.
    let drop_sql = format!(r#"DROP SCHEMA IF EXISTS "{schema}" CASCADE"#);
    if let Err(e) = admin.execute(drop_sql.as_str()).await {
        eprintln!("warning: failed to drop test schema {schema}: {e}");
    }

    // Now surface migration failures.
    match migration_outcome {
        Ok(Ok(applied)) => {
            assert!(
                applied >= 1,
                "expected at least 1 migration to apply against empty schema"
            );
        }
        Ok(Err(e)) => panic!("migrations failed against empty schema: {e}"),
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

async fn run_migrations_into_schema(base_url: &str, schema: &str) -> Result<usize, sqlx::Error> {
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(2)
        .connect(&url_with_search_path(base_url, schema))
        .await?;

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .map_err(|e| sqlx::Error::Migrate(Box::new(e)))?;

    // Count applied migrations from sqlx's tracking table inside the schema.
    let (count,): (i64,) = sqlx::query_as(r#"SELECT COUNT(*) FROM _sqlx_migrations"#)
        .fetch_one(&pool)
        .await?;

    // TD-66: lock down a handful of schema invariants. A migration that
    // forgot to mark a column NOT NULL, used the wrong data type, or
    // dropped a critical index would pass the bare `count > 0` check
    // unchanged — these assertions catch it.
    assert_column_invariants(&pool).await?;
    assert_index_invariants(&pool).await?;

    pool.close().await;
    Ok(count as usize)
}

/// TD-66: assert critical column existence / nullability / type.
///
/// Each entry: `(table, column, expected_data_type, expected_nullable)`.
/// `expected_data_type` matches `information_schema.columns.data_type`.
async fn assert_column_invariants(pool: &sqlx::PgPool) -> Result<(), sqlx::Error> {
    const INVARIANTS: &[(&str, &str, &str, &str)] = &[
        // Refresh-token family wiring — drives the theft-detection family
        // revoke; mis-typed columns silently break the chain. `family_id`
        // is nullable because the migration that added it didn't backfill
        // pre-existing rows; new rows always get a value via the default.
        ("refresh_tokens", "family_id", "uuid", "YES"),
        ("refresh_tokens", "revoked", "boolean", "NO"),
        // Soft-delete invariant — every query in `db/messages.rs` filters
        // on `deleted_at IS NULL`; flipping to NOT NULL would resurrect
        // tombstones.
        ("messages", "deleted_at", "timestamp with time zone", "YES"),
        // Per-message TTL column the disappearing-messages sweep relies on.
        ("messages", "expires_at", "timestamp with time zone", "YES"),
        // Per-device key fingerprint binding — defeats signing-key-only MITM.
        ("identity_keys", "fingerprint", "bytea", "YES"),
        (
            "identity_keys",
            "revoked_at",
            "timestamp with time zone",
            "YES",
        ),
        // Group-key envelope schema; integer key_version drives version
        // monotonicity guarantees.
        ("group_key_envelopes", "key_version", "integer", "NO"),
        ("group_key_envelopes", "encrypted_key", "text", "NO"),
        // Feedback diagnostic context (TD-57 / beta migration).
        ("feedback", "app_version", "text", "YES"),
        ("feedback", "platform", "text", "YES"),
        ("feedback", "logs", "text", "YES"),
        // Conversation member soft-delete invariant.
        ("conversation_members", "is_removed", "boolean", "NO"),
        // Invite-token use accounting — integer with a max-uses check.
        // max_uses NULL means "unlimited"; use_count is always set.
        ("group_invite_tokens", "use_count", "integer", "NO"),
        ("group_invite_tokens", "max_uses", "integer", "YES"),
        // Password-reset audit columns the cleanup task scans on.
        (
            "password_reset_tokens",
            "expires_at",
            "timestamp with time zone",
            "NO",
        ),
        (
            "password_reset_tokens",
            "used_at",
            "timestamp with time zone",
            "YES",
        ),
    ];

    for (table, column, expected_type, expected_nullable) in INVARIANTS {
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT data_type, is_nullable FROM information_schema.columns \
             WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
        )
        .bind(table)
        .bind(column)
        .fetch_optional(pool)
        .await?;

        let (data_type, is_nullable) =
            row.unwrap_or_else(|| panic!("missing column {table}.{column}"));
        assert_eq!(
            data_type, *expected_type,
            "{table}.{column}: expected type {expected_type}, got {data_type}",
        );
        assert_eq!(
            is_nullable, *expected_nullable,
            "{table}.{column}: expected nullable={expected_nullable}, got {is_nullable}",
        );
    }

    Ok(())
}

/// TD-66: assert critical indexes exist (and so the planner can use them).
///
/// These names track the actual SQL filenames; if a migration is renamed in
/// the future, this assertion will catch a missing index.
async fn assert_index_invariants(pool: &sqlx::PgPool) -> Result<(), sqlx::Error> {
    const INDEXES: &[(&str, &str)] = &[
        ("messages", "idx_messages_conv"),
        ("messages", "idx_messages_conv_created_desc"),
        ("group_key_envelopes", "idx_group_key_envelopes_recipient"),
        ("feedback", "feedback_status_created_at_idx"),
        ("feedback", "feedback_user_id_created_at_idx"),
    ];

    for (table, index) in INDEXES {
        let row: Option<(String,)> = sqlx::query_as(
            "SELECT indexname FROM pg_indexes \
             WHERE schemaname = current_schema() AND tablename = $1 AND indexname = $2",
        )
        .bind(table)
        .bind(index)
        .fetch_optional(pool)
        .await?;
        assert!(
            row.is_some(),
            "expected index {index} on {table} to exist after migration",
        );
    }

    Ok(())
}
