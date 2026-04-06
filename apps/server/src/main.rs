use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::ws::Message as WsMessage;
use echo_server::{config, db, routes, ws};
use sqlx::PgPool;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    // Load .env file
    dotenvy::dotenv().ok();

    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    tracing::info!("Starting Echo server v{}", env!("CARGO_PKG_VERSION"));

    // Ensure upload directories exist (Docker volume mounts may override build-time mkdir)
    std::fs::create_dir_all("./uploads/avatars").expect("Failed to create uploads directory");

    // Load configuration
    let config = config::Config::from_env();

    // Create database pool and run migrations
    let pool = db::create_pool(&config.database_url).await;
    db::run_migrations(&pool).await;

    // Build app state and router
    let hub = ws::hub::Hub::new();
    let state = Arc::new(routes::AppState {
        pool: pool.clone(),
        jwt_secret: config.jwt_secret,
        hub: hub.clone(),
        ticket_store: Mutex::new(HashMap::new()),
    });

    // Background task: clean up stale voice sessions every 60 seconds.
    // Sessions not updated within 2 minutes are removed and leave events
    // are broadcast to group members.
    let cleanup_pool = pool.clone();
    let cleanup_hub = hub.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            cleanup_stale_voice_sessions(&cleanup_pool, &cleanup_hub).await;
            cleanup_empty_groups(&cleanup_pool).await;
        }
    });

    let app = routes::create_router(state);

    // Start server
    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid address");
    tracing::info!("Listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind");

    // Graceful shutdown via Ctrl+C
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn(async move {
        tokio::signal::ctrl_c().await.ok();
        tracing::info!("Shutting down gracefully...");
        shutdown_tx.send(()).ok();
    });

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        shutdown_rx.await.ok();
    })
    .await
    .expect("Server error");
}

/// Remove voice sessions not updated within 2 minutes and broadcast leave events.
async fn cleanup_stale_voice_sessions(pool: &PgPool, hub: &ws::hub::Hub) {
    let removed = match db::channels::cleanup_stale_voice_sessions(pool, 120).await {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("Voice session cleanup error: {e}");
            return;
        }
    };

    for (channel_id, conversation_id, user_id) in removed {
        tracing::info!("Cleaned stale voice session: user={user_id} channel={channel_id}");
        broadcast_voice_session_left(pool, hub, channel_id, conversation_id, user_id).await;
    }
}

/// Broadcast a voice_session_left event to all members of a conversation.
async fn broadcast_voice_session_left(
    pool: &PgPool,
    hub: &ws::hub::Hub,
    channel_id: uuid::Uuid,
    conversation_id: uuid::Uuid,
    user_id: uuid::Uuid,
) {
    let member_ids = match db::groups::get_conversation_member_ids(pool, conversation_id).await {
        Ok(ids) => ids,
        Err(_) => return,
    };

    let event = serde_json::json!({
        "type": "voice_session_left",
        "group_id": conversation_id,
        "channel_id": channel_id,
        "user_id": user_id,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        for member_id in &member_ids {
            hub.send_to(member_id, WsMessage::Text(json.clone().into()));
        }
    }
}

/// Delete empty groups (zero members) and all their dependent rows.
async fn cleanup_empty_groups(pool: &PgPool) {
    let empty_group_ids: Vec<(uuid::Uuid,)> = sqlx::query_as(
        "SELECT id FROM conversations WHERE kind = 'group' \
         AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)",
    )
    .fetch_all(pool)
    .await
    .unwrap_or_default();

    for (gid,) in &empty_group_ids {
        delete_group_dependents(pool, *gid).await;
    }
}

/// Delete all dependent rows for a group conversation, then delete the conversation itself.
async fn delete_group_dependents(pool: &PgPool, gid: uuid::Uuid) {
    let _ = sqlx::query(
        "DELETE FROM voice_sessions WHERE channel_id IN \
         (SELECT id FROM channels WHERE conversation_id = $1)",
    )
    .bind(gid)
    .execute(pool)
    .await;
    let _ = sqlx::query("DELETE FROM channels WHERE conversation_id = $1")
        .bind(gid)
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM messages WHERE conversation_id = $1")
        .bind(gid)
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM group_keys WHERE conversation_id = $1")
        .bind(gid)
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM banned_members WHERE conversation_id = $1")
        .bind(gid)
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM read_receipts WHERE conversation_id = $1")
        .bind(gid)
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM media WHERE conversation_id = $1")
        .bind(gid)
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM conversations WHERE id = $1")
        .bind(gid)
        .execute(pool)
        .await;
}
