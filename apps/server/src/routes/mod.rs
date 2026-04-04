pub mod auth;
pub mod channels;
pub mod contacts;
pub mod groups;
pub mod keys;
pub mod media;
pub mod messages;
pub mod reactions;
pub mod users;
pub mod ws;

use axum::Json;
use axum::Router;
use axum::http::{HeaderValue, Method, header};
use axum::middleware;
use axum::response::IntoResponse;
use axum::routing::{delete, get, post, put};
use sqlx::PgPool;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::set_header::SetResponseHeaderLayer;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::middleware::rate_limit;
use crate::ws::hub::Hub;

/// Map from ticket string to (user_id, created_at).
pub type TicketStore = Mutex<HashMap<String, (Uuid, Instant)>>;

pub struct AppState {
    pub pool: PgPool,
    pub jwt_secret: String,
    pub hub: Hub,
    pub ticket_store: TicketStore,
}

pub fn create_router(state: Arc<AppState>) -> Router {
    let cors_origins = std::env::var("CORS_ORIGINS")
        .unwrap_or_else(|_| "https://echo-messenger.us,http://localhost:8081".into());

    let allowed_methods = [
        Method::GET,
        Method::POST,
        Method::PUT,
        Method::DELETE,
        Method::OPTIONS,
    ];
    let allowed_headers = [header::CONTENT_TYPE, header::AUTHORIZATION];

    let cors = if cors_origins == "*" {
        CorsLayer::new()
            .allow_origin(AllowOrigin::any())
            .allow_methods(allowed_methods)
            .allow_headers(allowed_headers)
    } else {
        let origins: Vec<HeaderValue> = cors_origins
            .split(',')
            .filter_map(|s| s.trim().parse().ok())
            .collect();
        CorsLayer::new()
            .allow_origin(AllowOrigin::list(origins))
            .allow_methods(allowed_methods)
            .allow_headers(allowed_headers)
    };

    let login_limit = rate_limit::make_rate_limit_layer(rate_limit::login_limiter());
    let register_limit = rate_limit::make_rate_limit_layer(rate_limit::register_limiter());

    let auth_routes = Router::new()
        .route(
            "/register",
            post(auth::register).layer(middleware::from_fn(register_limit)),
        )
        .route(
            "/login",
            post(auth::login).layer(middleware::from_fn(login_limit)),
        )
        .route("/refresh", post(auth::refresh))
        .route("/logout", post(auth::logout))
        .route("/ws-ticket", post(auth::ws_ticket));

    let contact_routes = Router::new()
        .route("/", get(contacts::list_contacts))
        .route("/request", post(contacts::send_request))
        .route("/accept", post(contacts::accept_request))
        .route("/pending", get(contacts::list_pending))
        .route("/block", post(contacts::block_user))
        .route("/unblock", post(contacts::unblock_user))
        .route("/blocked", get(contacts::list_blocked));

    let message_routes = Router::new()
        .route("/conversations", get(messages::list_conversations))
        .route("/conversations/dm", post(messages::create_dm))
        .route(
            "/conversations/{conversation_id}/read",
            post(reactions::mark_read),
        )
        .route(
            "/conversations/{conversation_id}/search",
            get(messages::search_messages),
        )
        .route(
            "/conversations/{conversation_id}/mute",
            put(messages::toggle_mute),
        )
        .route(
            "/messages/{id}",
            get(messages::get_messages)
                .delete(messages::delete_message)
                .put(messages::edit_message),
        )
        .route("/messages/{id}/reactions", post(reactions::add_reaction))
        .route(
            "/messages/{message_id}/reactions/{emoji}",
            delete(reactions::remove_reaction),
        );

    let key_routes = Router::new()
        .route("/upload", post(keys::upload_bundle))
        .route("/bundle/{user_id}", get(keys::get_bundle))
        .route(
            "/bundle/{user_id}/{device_id}",
            get(keys::get_device_bundle),
        )
        .route("/devices/{user_id}", get(keys::get_devices));

    let media_routes = Router::new()
        .route("/upload", post(media::upload))
        .route("/{id}", get(media::download));

    let group_routes = Router::new()
        .route("/", post(groups::create_group))
        .route("/public", get(groups::list_public_groups))
        .route(
            "/{id}/channels",
            get(channels::list_channels).post(channels::create_channel),
        )
        .route(
            "/{id}/channels/{channel_id}",
            put(channels::update_channel).delete(channels::delete_channel),
        )
        .route(
            "/{id}/channels/{channel_id}/voice",
            get(channels::list_voice_sessions),
        )
        .route(
            "/{id}/channels/{channel_id}/voice/participants",
            get(channels::list_voice_sessions),
        )
        .route(
            "/{id}/channels/{channel_id}/voice/join",
            post(channels::join_voice_channel),
        )
        .route(
            "/{id}/channels/{channel_id}/voice/leave",
            post(channels::leave_voice_channel),
        )
        .route(
            "/{id}/channels/{channel_id}/voice/state",
            put(channels::update_voice_state),
        )
        .route(
            "/{id}",
            get(groups::get_group)
                .put(groups::update_group)
                .delete(groups::delete_group),
        )
        .route("/{id}/members", post(groups::add_member))
        .route("/{id}/members/{user_id}", delete(groups::remove_member))
        .route("/{id}/join", post(groups::join_group))
        .route("/{id}/leave", post(groups::leave_group))
        .route("/{id}/ban/{user_id}", post(groups::ban_member))
        .route("/{id}/unban/{user_id}", post(groups::unban_member));

    let user_routes = Router::new()
        .route("/me", delete(users::delete_account))
        .route(
            "/me/privacy",
            get(users::get_my_privacy).patch(users::update_my_privacy),
        )
        .route("/me/avatar", put(users::upload_avatar))
        .route("/online", get(users::online_users))
        .route("/{id}/profile", get(users::get_profile))
        .route("/{id}/avatar", get(users::get_avatar));

    Router::new()
        .nest("/api/auth", auth_routes)
        .nest("/api/contacts", contact_routes)
        .nest("/api/keys", key_routes)
        .nest("/api/groups", group_routes)
        .nest("/api/users", user_routes)
        .nest("/api/media", media_routes)
        .nest("/api", message_routes)
        .route("/api/health", get(health))
        .route("/api/config/ice", get(ice_config))
        .route("/ws", get(ws::ws_upgrade))
        .layer(cors)
        .layer(SetResponseHeaderLayer::overriding(
            header::HeaderName::from_static("x-content-type-options"),
            header::HeaderValue::from_static("nosniff"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::HeaderName::from_static("x-frame-options"),
            header::HeaderValue::from_static("DENY"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::HeaderName::from_static("x-xss-protection"),
            header::HeaderValue::from_static("1; mode=block"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::STRICT_TRANSPORT_SECURITY,
            header::HeaderValue::from_static("max-age=31536000; includeSubDomains"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::CONTENT_SECURITY_POLICY,
            header::HeaderValue::from_static("default-src 'self'"),
        ))
        .with_state(state)
}

pub async fn health() -> impl IntoResponse {
    Json(serde_json::json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "server": "Echo Messenger"
    }))
}

/// Returns ICE server configuration from environment variables.
/// Set TURN_URL, TURN_USERNAME, TURN_CREDENTIAL to configure TURN.
pub async fn ice_config(_auth: AuthUser) -> impl IntoResponse {
    let mut servers = vec![serde_json::json!({"urls": "stun:stun.l.google.com:19302"})];

    if let Ok(turn_url) = std::env::var("TURN_URL") {
        let username = std::env::var("TURN_USERNAME").unwrap_or_default();
        let credential = std::env::var("TURN_CREDENTIAL").unwrap_or_default();
        servers.push(serde_json::json!({
            "urls": turn_url,
            "username": username,
            "credential": credential,
        }));
    }

    Json(serde_json::json!({ "iceServers": servers }))
}
