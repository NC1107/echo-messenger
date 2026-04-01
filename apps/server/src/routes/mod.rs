pub mod auth;
pub mod contacts;
pub mod groups;
pub mod keys;
pub mod media;
pub mod messages;
pub mod reactions;
pub mod ws;

use axum::Json;
use axum::Router;
use axum::response::IntoResponse;
use axum::routing::{delete, get, post};
use sqlx::PgPool;
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};

use crate::ws::hub::Hub;

pub struct AppState {
    pub pool: PgPool,
    pub jwt_secret: String,
    pub hub: Hub,
}

pub fn create_router(state: Arc<AppState>) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let auth_routes = Router::new()
        .route("/register", post(auth::register))
        .route("/login", post(auth::login));

    let contact_routes = Router::new()
        .route("/", get(contacts::list_contacts))
        .route("/request", post(contacts::send_request))
        .route("/accept", post(contacts::accept_request))
        .route("/pending", get(contacts::list_pending));

    let message_routes = Router::new()
        .route("/conversations", get(messages::list_conversations))
        .route(
            "/conversations/{conversation_id}/read",
            post(reactions::mark_read),
        )
        .route("/messages/{conversation_id}", get(messages::get_messages))
        .route(
            "/messages/{message_id}/reactions",
            post(reactions::add_reaction),
        )
        .route(
            "/messages/{message_id}/reactions/{emoji}",
            delete(reactions::remove_reaction),
        );

    let key_routes = Router::new()
        .route("/upload", post(keys::upload_bundle))
        .route("/bundle/{user_id}", get(keys::get_bundle));

    let media_routes = Router::new()
        .route("/upload", post(media::upload))
        .route("/{id}", get(media::download));

    let group_routes = Router::new()
        .route("/", post(groups::create_group))
        .route("/public", get(groups::list_public_groups))
        .route("/{id}", get(groups::get_group))
        .route("/{id}/members", post(groups::add_member))
        .route("/{id}/members/{user_id}", delete(groups::remove_member))
        .route("/{id}/join", post(groups::join_group))
        .route("/{id}/leave", post(groups::leave_group));

    Router::new()
        .nest("/api/auth", auth_routes)
        .nest("/api/contacts", contact_routes)
        .nest("/api/keys", key_routes)
        .nest("/api/groups", group_routes)
        .nest("/api/media", media_routes)
        .nest("/api", message_routes)
        .route("/api/health", get(health))
        .route("/ws", get(ws::ws_upgrade))
        .layer(cors)
        .with_state(state)
}

pub async fn health() -> impl IntoResponse {
    Json(serde_json::json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "server": "Echo Messenger"
    }))
}
