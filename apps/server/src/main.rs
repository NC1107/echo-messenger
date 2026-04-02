use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use tracing_subscriber::EnvFilter;

mod auth;
mod config;
mod db;
mod error;
mod middleware;
mod routes;
mod ws;

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
        pool,
        jwt_secret: config.jwt_secret,
        hub,
        ticket_store: Mutex::new(HashMap::new()),
        livekit_api_key: config.livekit_api_key,
        livekit_api_secret: config.livekit_api_secret,
        livekit_url: config.livekit_url,
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
