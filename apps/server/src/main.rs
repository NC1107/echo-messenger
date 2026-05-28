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
    let metrics_token = std::env::var("METRICS_TOKEN")
        .ok()
        .filter(|t| !t.is_empty());
    if metrics_token.is_some() {
        tracing::info!("Prometheus metrics endpoint enabled at /api/metrics");
    } else {
        tracing::info!("Prometheus metrics endpoint disabled (set METRICS_TOKEN to enable)");
    }

    let state = Arc::new(routes::AppState {
        pool: pool.clone(),
        jwt_secret: config.jwt_secret,
        hub: hub.clone(),
        ticket_store: Arc::new(dashmap::DashMap::new()),
        media_tickets: Arc::new(dashmap::DashMap::new()),
        message_rate: Arc::new(echo_server::metrics::MessageRateCounter::new()),
        token_invalidator: echo_server::auth::TokenInvalidator::new(),
        failed_logins: Arc::new(echo_server::metrics::SimpleCounter::new()),
        voice_tokens_issued: Arc::new(echo_server::metrics::SimpleCounter::new()),
        metrics_token,
        canvas_authority: ws::CanvasAuthority::new(),
    });

    // TD-37: cooperative shutdown so DELETE/UPDATE batches finish cleanly.
    let shutdown_token = tokio_util::sync::CancellationToken::new();
    let mut periodic_handles: Vec<tokio::task::JoinHandle<()>> = Vec::new();

    // Per-task cleanup loops with panic recovery; cadence per task.
    periodic_handles.push(spawn_periodic(
        "voice_sessions",
        std::time::Duration::from_secs(60),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            let hub = hub.clone();
            move || {
                let pool = pool.clone();
                let hub = hub.clone();
                async move { cleanup_stale_voice_sessions(&pool, &hub).await }
            }
        },
    ));
    periodic_handles.push(spawn_periodic(
        "expired_messages",
        std::time::Duration::from_secs(30),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            let hub = hub.clone();
            move || {
                let pool = pool.clone();
                let hub = hub.clone();
                async move { cleanup_expired_messages(&pool, &hub).await }
            }
        },
    ));
    periodic_handles.push(spawn_periodic(
        "expired_tokens",
        std::time::Duration::from_secs(600),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            move || {
                let pool = pool.clone();
                async move { cleanup_expired_tokens(&pool).await }
            }
        },
    ));
    // TD-57: reap password-reset tokens hourly so the table doesn't grow
    // under brute-force abuse.
    periodic_handles.push(spawn_periodic(
        "password_reset_tokens",
        std::time::Duration::from_secs(3600),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            move || {
                let pool = pool.clone();
                async move { cleanup_expired_password_reset_tokens(&pool).await }
            }
        },
    ));
    periodic_handles.push(spawn_periodic(
        "used_prekeys",
        std::time::Duration::from_secs(600),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            move || {
                let pool = pool.clone();
                async move { cleanup_used_prekeys(&pool).await }
            }
        },
    ));
    periodic_handles.push(spawn_periodic(
        "empty_groups",
        std::time::Duration::from_secs(300),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            move || {
                let pool = pool.clone();
                async move { cleanup_empty_groups(&pool).await }
            }
        },
    ));
    periodic_handles.push(spawn_periodic(
        "orphan_media",
        std::time::Duration::from_secs(3600),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            move || {
                let pool = pool.clone();
                async move { cleanup_orphan_media_files(&pool).await }
            }
        },
    ));
    // Sweep abandoned chunked-upload sessions hourly (#556).  Idle window is
    // 24 h so a user who closed their laptop overnight can still resume.
    periodic_handles.push(spawn_periodic(
        "stale_uploads",
        std::time::Duration::from_secs(3600),
        shutdown_token.clone(),
        {
            let pool = pool.clone();
            move || {
                let pool = pool.clone();
                async move {
                    echo_server::routes::media_chunked::cleanup_stale_uploads(&pool, 24 * 60 * 60)
                        .await
                }
            }
        },
    ));

    // Evict stale entries from the typing_service membership/member-ID/conv-kind
    // caches; without this, entries accumulate unboundedly on long-running servers.
    periodic_handles.push(spawn_periodic(
        "cache_sweep",
        std::time::Duration::from_secs(300),
        shutdown_token.clone(),
        || async {
            ws::typing_service::sweep_expired_caches();
        },
    ));

    let app = routes::create_router(state, config.trusted_proxies);

    // Start server
    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid address");
    tracing::info!("Listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind");

    // TD-37: two-stage drain — cancel periodics, then axum graceful shutdown,
    // then await every periodic handle before exit.
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    {
        let shutdown_token = shutdown_token.clone();
        tokio::spawn(async move {
            tokio::signal::ctrl_c().await.ok();
            tracing::info!("Shutting down gracefully...");
            shutdown_token.cancel();
            shutdown_tx.send(()).ok();
        });
    }

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        shutdown_rx.await.ok();
    })
    .await
    .expect("Server error");

    // Wind down background loops too before exit.
    shutdown_token.cancel();
    for handle in periodic_handles {
        if let Err(e) = handle.await {
            tracing::warn!("periodic task join error during shutdown: {e}");
        }
    }
}

/// Periodic task with panic recovery and cooperative shutdown.
///
/// `make_fut` is a stateless re-creator; captured `Arc` clones make
/// `AssertUnwindSafe` sound. The loop exits when `shutdown` fires so SIGTERM
/// no longer tears DELETE statements at arbitrary instructions (TD-37). The
/// returned `JoinHandle` is collected by `main` so we can await all
/// outstanding periodic tasks during graceful shutdown.
fn spawn_periodic<F, Fut>(
    name: &'static str,
    period: std::time::Duration,
    shutdown: tokio_util::sync::CancellationToken,
    mut make_fut: F,
) -> tokio::task::JoinHandle<()>
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
            tokio::select! {
                biased;
                _ = shutdown.cancelled() => {
                    tracing::debug!(task = name, "periodic task shutting down");
                    return;
                }
                _ = interval.tick() => {}
            }

            // Race against shutdown so we don't start a fresh batch mid-drain.
            let fut = make_fut();
            let work = std::panic::AssertUnwindSafe(Box::pin(fut)).catch_unwind();
            let result = tokio::select! {
                biased;
                _ = shutdown.cancelled() => {
                    tracing::debug!(task = name, "periodic task shutting down mid-batch");
                    return;
                }
                r = work => r,
            };
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
    })
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

/// Delete empty groups (zero ACTIVE members) and all their dependent rows.
///
/// #829: previously the inner SELECT did not filter `is_removed = false`,
/// so a group whose only members were all soft-removed (tombstones) was
/// never reaped. The query is now in `db::groups::find_empty_group_ids`
/// (so the integration test can exercise it directly) and uses `NOT EXISTS`
/// for cleaner planner behaviour on large `conversation_members` tables.
async fn cleanup_empty_groups(pool: &PgPool) {
    let empty_group_ids = match db::groups::find_empty_group_ids(pool).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::error!("cleanup_empty_groups: find_empty_group_ids failed: {e}");
            return;
        }
    };

    for gid in &empty_group_ids {
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

/// TD-57: reap expired password-reset tokens (used or unused) so the table
/// doesn't grow unboundedly under brute-force abuse. The 24-hour cliff is
/// loose enough that any pending support flow has finished; consumed
/// tokens are also pruned by `used_at` so we don't keep a permanent record
/// of every reset request.
async fn cleanup_expired_password_reset_tokens(pool: &PgPool) {
    let result = sqlx::query(
        "DELETE FROM password_reset_tokens \
         WHERE expires_at < now() - interval '24 hours' \
            OR used_at IS NOT NULL",
    )
    .execute(pool)
    .await;

    match result {
        Ok(r) if r.rows_affected() > 0 => {
            tracing::info!(
                "Cleaned {} expired/consumed password-reset tokens",
                r.rows_affected()
            );
        }
        Err(e) => tracing::warn!("Password-reset token cleanup error: {e}"),
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
///
/// TD-52: batched + member-list cached per-conversation. The DB query
/// returns up to 500 expirations at a time; we re-invoke it in a loop
/// until empty so a 10 000-message backlog drains without holding the
/// whole list in memory. Per-conversation member fetches are now cached
/// for the duration of one sweep — previously a 1 000-message group
/// expiry triggered 1 000 identical SELECTs.
async fn cleanup_expired_messages(pool: &PgPool, hub: &ws::hub::Hub) {
    let mut total = 0usize;
    loop {
        let expired = match db::messages::cleanup_expired_messages(pool).await {
            Ok(rows) => rows,
            Err(e) => {
                tracing::warn!("Expired message cleanup error: {e}");
                return;
            }
        };

        if expired.is_empty() {
            break;
        }
        let batch_len = expired.len();
        total += batch_len;

        // Group by conversation_id so each member-list fetch happens once
        // per conversation per batch.
        let mut by_conv: std::collections::HashMap<uuid::Uuid, Vec<uuid::Uuid>> =
            std::collections::HashMap::new();
        for (message_id, conversation_id) in expired {
            by_conv.entry(conversation_id).or_default().push(message_id);
        }

        for (conversation_id, message_ids) in by_conv {
            let member_ids =
                match db::groups::get_conversation_member_ids(pool, conversation_id).await {
                    Ok(ids) => ids,
                    Err(_) => continue,
                };
            for message_id in message_ids {
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

        // Smaller backlogs finish in one batch; bail out of the loop early
        // so we don't busy-poll an empty query right after.
        if batch_len < 500 {
            break;
        }
    }

    if total > 0 {
        tracing::info!("Cleaned {total} expired messages");
    }
}

/// Validate and extract UUID from a media file path.
/// Returns None if the file is not a recognized media format or UUID parsing fails.
fn extract_media_uuid(path: &std::path::Path) -> Option<uuid::Uuid> {
    const KNOWN_EXTENSIONS: &[&str] = &[
        "jpg", "png", "gif", "webp", "heic", "mp4", "mov", "webm", "avi", "mp3", "ogg", "wav",
        "m4a", "aac", "flac", "pdf", "txt", "doc", "docx", "xls", "xlsx", "zip", "7z", "tar", "gz",
        "bin",
    ];

    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if !KNOWN_EXTENSIONS.contains(&ext.as_str()) {
        return None;
    }

    let stem = path.file_stem().and_then(|s| s.to_str())?;
    let uuid_str = stem.trim_end_matches(".thumb");
    uuid::Uuid::parse_str(uuid_str).ok()
}

/// Check if a file is too new to reap (in-flight uploads within 5 minutes).
async fn is_file_too_new(entry: &tokio::fs::DirEntry, cutoff: std::time::SystemTime) -> bool {
    entry
        .metadata()
        .await
        .and_then(|m| m.modified())
        .map(|mtime| mtime > cutoff)
        .unwrap_or(true)
}

/// Scan `./uploads/` and remove files whose name UUID is absent from the
/// `media` table. Files younger than 5 minutes are skipped so in-flight
/// uploads not yet committed to the DB are never reaped.
async fn cleanup_orphan_media_files(pool: &PgPool) {
    let known_ids = match db::media::all_media_ids(pool).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!("Orphan media reaper: failed to fetch media IDs: {e}");
            return;
        }
    };

    let mut dir = match tokio::fs::read_dir("./uploads").await {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!("Orphan media reaper: cannot read uploads dir: {e}");
            return;
        }
    };

    let cutoff = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(300))
        .unwrap_or(std::time::UNIX_EPOCH);

    let mut reaped: u32 = 0;

    loop {
        let entry = match dir.next_entry().await {
            Ok(Some(e)) => e,
            Ok(None) => break,
            Err(e) => {
                tracing::warn!("Orphan media reaper: read_dir entry error: {e}");
                continue;
            }
        };

        let path = entry.path();

        let Some(file_uuid) = extract_media_uuid(&path) else {
            continue;
        };

        if known_ids.contains(&file_uuid) {
            continue;
        }

        if is_file_too_new(&entry, cutoff).await {
            continue;
        }

        if let Err(e) = tokio::fs::remove_file(&path).await {
            tracing::warn!("Orphan media reaper: failed to delete {:?}: {e}", path);
        } else {
            reaped += 1;
        }
    }

    if reaped > 0 {
        tracing::info!("Orphan media reaper: deleted {reaped} file(s)");
    }
}

/// Delete a group conversation and every dependent row atomically.
///
/// #785: migration 20260515100000 extended `ON DELETE CASCADE` to the last
/// remaining child FK (`media.conversation_id`), so every direct child and
/// transitive grandchild of `conversations` now cascades at the database
/// level. The historical 9-statement transactional cleanup has been
/// replaced by a single call to `force_delete_conversation`, which issues
/// `DELETE FROM conversations WHERE id = $1` and lets Postgres handle the
/// cascade. See `apps/server/tests/api_groups_cascade_delete.rs` for the
/// integration test that pins this contract.
async fn delete_group_dependents(pool: &PgPool, gid: uuid::Uuid) {
    if let Err(e) = db::groups::force_delete_conversation(pool, gid).await {
        tracing::error!(group_id = %gid, "force_delete_conversation failed: {e}");
    }
}
