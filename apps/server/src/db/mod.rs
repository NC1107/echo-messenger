pub mod canvas;
pub mod channels;
pub mod contacts;
pub mod group_key_rotations;
pub mod groups;
pub mod keys;
pub mod media;
pub mod mentions;
pub mod messages;
pub mod password_reset;
pub mod polls;
pub mod push_tokens;
pub mod reactions;
pub mod tokens;
pub mod upload_sessions;
pub mod users;

use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;

/// Attempt to connect to PostgreSQL with exponential back-off.
///
/// Docker Compose `depends_on: condition: service_healthy` is the primary
/// guard, but the DB process can still be accepting TCP connections before it
/// is ready to serve queries (e.g. during crash-recovery replay).  This retry
/// loop handles that narrow window without requiring orchestration changes.
///
/// Delays (seconds): 1, 2, 4, 8, 16 → gives up after ~31 s of total wait.
pub async fn create_pool(database_url: &str) -> PgPool {
    let max_conns: u32 = std::env::var("DB_MAX_CONNECTIONS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(30);

    const MAX_RETRIES: u32 = 5;
    let mut delay_secs = 1u64;

    // TD-56: warm pool + 15s acquire so idle-recovery + bursts don't 500.
    let min_conns: u32 = std::env::var("DB_MIN_CONNECTIONS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(5)
        .min(max_conns);

    for attempt in 1..=MAX_RETRIES {
        match PgPoolOptions::new()
            .max_connections(max_conns)
            .min_connections(min_conns)
            .acquire_timeout(std::time::Duration::from_secs(15))
            .idle_timeout(std::time::Duration::from_secs(300))
            .connect(database_url)
            .await
        {
            Ok(pool) => {
                if attempt > 1 {
                    tracing::info!("Connected to database after {} attempts", attempt);
                }
                return pool;
            }
            Err(err) if attempt < MAX_RETRIES => {
                tracing::warn!(
                    attempt,
                    retry_in_secs = delay_secs,
                    %err,
                    "Database connection failed; retrying"
                );
                tokio::time::sleep(std::time::Duration::from_secs(delay_secs)).await;
                delay_secs *= 2;
            }
            Err(err) => {
                panic!("Failed to connect to database after {MAX_RETRIES} attempts: {err}");
            }
        }
    }
    unreachable!()
}

pub async fn run_migrations(pool: &PgPool) {
    sqlx::migrate!("./migrations")
        .run(pool)
        .await
        .expect("Failed to run database migrations");
    tracing::info!("Database migrations complete");
}
