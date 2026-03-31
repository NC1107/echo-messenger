pub mod auth;
pub mod contacts;
pub mod keys;
pub mod messages;
pub mod ws;

use axum::routing::{get, post};
use axum::Router;
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
            "/messages/{conversation_id}",
            get(messages::get_messages),
        );

    let key_routes = Router::new()
        .route("/upload", post(keys::upload_bundle))
        .route("/bundle/{user_id}", get(keys::get_bundle));

    Router::new()
        .nest("/api/auth", auth_routes)
        .nest("/api/contacts", contact_routes)
        .nest("/api/keys", key_routes)
        .nest("/api", message_routes)
        .route("/ws", get(ws::ws_upgrade))
        .layer(cors)
        .with_state(state)
}
