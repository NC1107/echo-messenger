pub mod contacts;
pub mod keys;
pub mod messages;
pub mod users;

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

pub async fn create_pool(database_url: &str) -> PgPool {
    PgPoolOptions::new()
        .max_connections(10)
        .connect(database_url)
        .await
        .expect("Failed to connect to database")
}

pub async fn run_migrations(pool: &PgPool) {
    let migrations: &[&str] = &[
        include_str!("../migrations/001_initial.sql"),
        include_str!("../migrations/002_messaging.sql"),
        include_str!("../migrations/003_keys.sql"),
    ];

    // Execute each statement separately (sqlx doesn't support multiple statements in one query)
    for migration_sql in migrations {
        for statement in migration_sql.split(';') {
            let trimmed = statement.trim();
            if trimmed.is_empty() {
                continue;
            }
            sqlx::query(trimmed)
                .execute(pool)
                .await
                .expect("Failed to run migration statement");
        }
    }

    tracing::info!("Database migrations complete");
}
