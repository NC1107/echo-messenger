use std::net::SocketAddr;
use std::sync::Arc;

use axum::extract::ws::Message as WsMessage;
use echo_server::ws::handler::ServerMessage;
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
        ticket_store: dashmap::DashMap::new(),
        media_tickets: dashmap::DashMap::new(),
    });

    // Audit #625: each cleanup runs in its own task with per-task cadence
    // and panic recovery (catch_unwind on the future).  Previously all five
    // shared one 60s loop, so a panic anywhere killed every cleanup
    // silently.  Cadences: voice + expired-messages stay tight (60s / 30s)
    // because their UX impact is immediate; tokens/prekeys/empty-groups
    // are hygiene tasks at lower frequency.
    spawn_periodic("voice_sessions", std::time::Duration::from_secs(60), {
        let pool = pool.clone();
        let hub = hub.clone();
        move || {
            let pool = pool.clone();
            let hub = hub.clone();
            async move { cleanup_stale_voice_sessions(&pool, &hub).await }
        }
    });
    spawn_periodic("expired_messages", std::time::Duration::from_secs(30), {
        let pool = pool.clone();
        let hub = hub.clone();
        move || {
            let pool = pool.clone();
            let hub = hub.clone();
            async move { cleanup_expired_messages(&pool, &hub).await }
        }
    });
    spawn_periodic("expired_tokens", std::time::Duration::from_secs(600), {
        let pool = pool.clone();
        move || {
            let pool = pool.clone();
            async move { cleanup_expired_tokens(&pool).await }
        }
    });
    spawn_periodic("used_prekeys", std::time::Duration::from_secs(600), {
        let pool = pool.clone();
        move || {
            let pool = pool.clone();
            async move { cleanup_used_prekeys(&pool).await }
        }
    });
    spawn_periodic("empty_groups", std::time::Duration::from_secs(300), {
        let pool = pool.clone();
        move || {
            let pool = pool.clone();
            async move { cleanup_empty_groups(&pool).await }
        }
    });

    // Cache eviction sweep on the membership/typing/conv-kind caches in
    // typing_service.  Bounded growth without this -- the audit (#692) found
    // entries never expire after 24h on a busy server.
    spawn_periodic(
        "cache_sweep",
        std::time::Duration::from_secs(300),
        || async {
            ws::typing_service::sweep_expired_caches();
        },
    );

    let app = routes::create_router(state, config.trusted_proxies);

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

/// Spawn a periodic cleanup task that recovers from panics.
///
/// Each task gets its own `tokio::spawn` so a panic anywhere doesn't kill
/// the others (audit #625).  `AssertUnwindSafe` is sound here because the
/// closures we pass are stateless re-creators -- they capture `Arc` clones
/// of pool/hub and rebuild a fresh future per tick, so any partially-
/// mutated state from a panicked invocation is dropped on unwind.
fn spawn_periodic<F, Fut>(name: &'static str, period: std::time::Duration, mut make_fut: F)
where
    F: FnMut() -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    use futures_util::FutureExt;
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(period);
        // Skip the immediate-fire first tick so we don't pile work onto
        // server boot, when the pool may still be warming.
        interval.tick().await;
        loop {
            interval.tick().await;
            let fut = make_fut();
            // catch_unwind requires Unpin; box-pin the future so we can
            // call AssertUnwindSafe + catch_unwind on it.
            let result = std::panic::AssertUnwindSafe(Box::pin(fut))
                .catch_unwind()
                .await;
            if let Err(panic) = result {
                tracing::error!(
                    task = name,
                    "cleanup task panicked: {:?}",
                    panic
                        .downcast_ref::<&str>()
                        .copied()
                        .or_else(|| panic.downcast_ref::<String>().map(String::as_str))
                        .unwrap_or("(non-string panic payload)")
                );
            }
        }
    });
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
        let msg = WsMessage::Text(json.as_str().into());
        for member_id in &member_ids {
            hub.send_to(member_id, msg.clone());
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

/// Remove expired or revoked refresh tokens to prevent unbounded table growth.
async fn cleanup_expired_tokens(pool: &PgPool) {
    let result = sqlx::query(
        "DELETE FROM refresh_tokens \
         WHERE expires_at < now() - interval '7 days' \
            OR (revoked = true AND created_at < now() - interval '1 day')",
    )
    .execute(pool)
    .await;

    match result {
        Ok(r) if r.rows_affected() > 0 => {
            tracing::info!(
                "Cleaned {} expired/revoked refresh tokens",
                r.rows_affected()
            );
        }
        Err(e) => tracing::warn!("Refresh token cleanup error: {e}"),
        _ => {}
    }
}

/// Remove consumed one-time prekeys that are no longer needed.
async fn cleanup_used_prekeys(pool: &PgPool) {
    let result = sqlx::query("DELETE FROM one_time_prekeys WHERE used = true")
        .execute(pool)
        .await;

    match result {
        Ok(r) if r.rows_affected() > 0 => {
            tracing::info!("Cleaned {} used one-time prekeys", r.rows_affected());
        }
        Err(e) => tracing::warn!("One-time prekey cleanup error: {e}"),
        _ => {}
    }
}

/// Delete messages whose `expires_at` has passed and broadcast `message_expired`
/// events to all online members of each affected conversation.
async fn cleanup_expired_messages(pool: &PgPool, hub: &ws::hub::Hub) {
    let expired = match db::messages::cleanup_expired_messages(pool).await {
        Ok(rows) => rows,
        Err(e) => {
            tracing::warn!("Expired message cleanup error: {e}");
            return;
        }
    };

    if expired.is_empty() {
        return;
    }

    tracing::info!("Cleaned {} expired messages", expired.len());

    for (message_id, conversation_id) in expired {
        // Notify all online members of the conversation.
        let member_ids = match db::groups::get_conversation_member_ids(pool, conversation_id).await
        {
            Ok(ids) => ids,
            Err(_) => continue,
        };

        let event = ServerMessage::MessageExpired {
            message_id,
            conversation_id,
        };
        if let Ok(json) = serde_json::to_string(&event) {
            let msg = WsMessage::Text(json.as_str().into());
            for member_id in &member_ids {
                hub.send_to(member_id, msg.clone());
            }
        }
    }
}

/// Delete all dependent rows for a group conversation, then the conversation
/// itself, atomically (audit #625, H32). Previously this was 9 sequential
/// pool queries with `if let Err(e) ...` swallows -- a connection drop after
/// step 4 left the conversation half-deleted and the next sweep picked it up
/// incompletely. Wrapped in one tx so the database is never observed in a
/// partially-cleaned state.
///
/// Migration 20260412000000 added ON DELETE CASCADE on a subset of child
/// tables (`messages`, `read_receipts`, `conversation_members`); the others
/// are still cleaned explicitly here. A follow-up migration that adds
/// CASCADE to `voice_sessions`, `channels`, `group_keys`,
/// `group_key_envelopes`, `banned_members`, and `media` would let this
/// collapse to `DELETE FROM conversations WHERE id = $1`.
async fn delete_group_dependents(pool: &PgPool, gid: uuid::Uuid) {
    let mut tx = match pool.begin().await {
        Ok(tx) => tx,
        Err(e) => {
            tracing::error!(group_id = %gid, "begin tx for group cleanup failed: {e}");
            return;
        }
    };

    let tables = [
        (
            "voice_sessions",
            "DELETE FROM voice_sessions WHERE channel_id IN (SELECT id FROM channels WHERE conversation_id = $1)",
        ),
        (
            "channels",
            "DELETE FROM channels WHERE conversation_id = $1",
        ),
        (
            "messages",
            "DELETE FROM messages WHERE conversation_id = $1",
        ),
        (
            "group_key_envelopes",
            "DELETE FROM group_key_envelopes WHERE conversation_id = $1",
        ),
        (
            "group_keys",
            "DELETE FROM group_keys WHERE conversation_id = $1",
        ),
        (
            "banned_members",
            "DELETE FROM banned_members WHERE conversation_id = $1",
        ),
        (
            "read_receipts",
            "DELETE FROM read_receipts WHERE conversation_id = $1",
        ),
        ("media", "DELETE FROM media WHERE conversation_id = $1"),
        ("conversations", "DELETE FROM conversations WHERE id = $1"),
    ];
    for (table, sql) in tables {
        if let Err(e) = sqlx::query(sql).bind(gid).execute(&mut *tx).await {
            tracing::error!(
                group_id = %gid,
                table = table,
                "group cleanup failed at {table}: {e} -- rolling back"
            );
            if let Err(rb) = tx.rollback().await {
                tracing::error!(group_id = %gid, "rollback failed: {rb}");
            }
            return;
        }
    }

    if let Err(e) = tx.commit().await {
        tracing::error!(group_id = %gid, "commit group cleanup failed: {e}");
    }
}
