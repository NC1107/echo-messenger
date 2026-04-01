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
    PgPoolOptions::new()
        .max_connections(50)
        .connect(database_url)
        .await
        .expect("Failed to connect to database")
}

pub async fn run_migrations(pool: &PgPool) {
    let migrations: &[&str] = &[
        include_str!("../migrations/001_initial.sql"),
        include_str!("../migrations/002_messaging.sql"),
        include_str!("../migrations/003_keys.sql"),
        include_str!("../migrations/004_reactions.sql"),
        include_str!("../migrations/005_media.sql"),
        include_str!("../migrations/006_public_groups.sql"),
        include_str!("../migrations/007_avatars_and_groups.sql"),
        include_str!("../migrations/008_refresh_tokens.sql"),
        include_str!("../migrations/009_performance_indexes.sql"),
        include_str!("../migrations/010_message_edit_delete_blocks.sql"),
        include_str!("../migrations/011_cascade_user_deletes.sql"),
        include_str!("../migrations/012_user_profile.sql"),
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
