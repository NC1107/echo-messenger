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

    pool.close().await;
    Ok(count as usize)
}
