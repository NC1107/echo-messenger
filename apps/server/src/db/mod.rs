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
        include_str!("../migrations/013_signal_device_keys.sql"),
        include_str!("../migrations/014_encryption_toggle.sql"),
        include_str!("../migrations/015_user_privacy_preferences.sql"),
        include_str!("../migrations/016_channels_and_voice.sql"),
        include_str!("../migrations/017_media_conversation_id.sql"),
        include_str!("../migrations/018_audit_indexes.sql"),
        include_str!("../migrations/019_message_replies.sql"),
    ];

    // Execute each statement separately (sqlx doesn't support multiple statements in one query)
    for migration_sql in migrations {
        for statement in migration_sql.split(';') {
            let trimmed = statement.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Err(e) = sqlx::query(trimmed).execute(pool).await {
                let msg = e.to_string();
                // Tolerate "already exists" errors from concurrent migration runs
                // (e.g. parallel integration tests).
                if msg.contains("already exists") || msg.contains("duplicate key") {
                    tracing::debug!("Migration statement skipped (already applied): {}", msg);
                } else {
                    panic!("Failed to run migration statement: {e}");
                }
            }
        }
    }

    tracing::info!("Database migrations complete");
}
