pub mod channels;
pub mod contacts;
pub mod groups;
pub mod keys;
pub mod media;
pub mod messages;
pub mod reactions;
pub mod tokens;
pub mod users;

use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;

pub async fn create_pool(database_url: &str) -> PgPool {
    let max_conns: u32 = std::env::var("DB_MAX_CONNECTIONS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(100);
    PgPoolOptions::new()
        .max_connections(max_conns)
        .connect(database_url)
        .await
        .expect("Failed to connect to database")
}

pub async fn run_migrations(pool: &PgPool) {
    sqlx::migrate!("./migrations")
        .run(pool)
        .await
        .expect("Failed to run database migrations");
    tracing::info!("Database migrations complete");
}
