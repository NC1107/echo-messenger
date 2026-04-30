pub mod auth;
pub mod canvas;
pub mod channels;
pub mod contacts;
pub mod group_keys;
pub mod groups;
pub mod keys;
pub mod link_preview;
pub mod media;
pub mod messages;
pub mod push;
pub mod reactions;
pub mod users;
pub mod voice;
pub mod ws;

use axum::Json;
use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::http::{HeaderValue, Method, header};
use axum::middleware;
use axum::response::IntoResponse;
use axum::routing::{delete, get, patch, post, put};
use dashmap::DashMap;
use sqlx::PgPool;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Instant;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::set_header::SetResponseHeaderLayer;
use uuid::Uuid;

use crate::middleware::rate_limit;
use crate::ws::hub::Hub;

/// Map from ticket string to (user_id, device_id, created_at).
/// Uses DashMap for lock-free concurrent access in async context.
pub type TicketStore = DashMap<String, (Uuid, i32, Instant)>;

/// Map from media ticket string to (user_id, created_at).
pub type MediaTicketStore = DashMap<String, (Uuid, Instant)>;

pub struct AppState {
    pub pool: PgPool,
    pub jwt_secret: String,
    pub hub: Hub,
    pub ticket_store: TicketStore,
    pub media_tickets: MediaTicketStore,
}

pub fn create_router(state: Arc<AppState>, trusted_proxies: Vec<IpAddr>) -> Router {
    let cors_origins = std::env::var("CORS_ORIGINS")
        .unwrap_or_else(|_| "https://echo-messenger.us,http://localhost:8081".into());

    let allowed_methods = [
        Method::GET,
        Method::POST,
        Method::PUT,
        Method::PATCH,
        Method::DELETE,
        Method::OPTIONS,
    ];
    let allowed_headers = [header::CONTENT_TYPE, header::AUTHORIZATION];

    let cors = if cors_origins == "*" {
        // Browsers reject `Access-Control-Allow-Credentials: true` paired with
        // `Access-Control-Allow-Origin: *`, so the wildcard branch CANNOT enable
        // credentials. The web client's HttpOnly refresh cookie (#342) requires
        // explicit origins -- set `CORS_ORIGINS` to a comma-separated list.
        tracing::warn!(
            "CORS_ORIGINS is set to '*' — allowing all origins WITHOUT credentials. \
             This is insecure for production and disables cookie-based refresh. \
             Set explicit origins to enable credentialed requests."
        );
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
            // Required for the web client to send the HttpOnly refresh cookie
            // back to /api/auth/refresh and /api/auth/logout (#342).
            .allow_credentials(true)
    };

    let proxies = Arc::new(trusted_proxies);
    let login_limit =
        rate_limit::make_rate_limit_layer(rate_limit::login_limiter(Arc::clone(&proxies)));
    let register_limit =
        rate_limit::make_rate_limit_layer(rate_limit::register_limiter(Arc::clone(&proxies)));
    let refresh_limit =
        rate_limit::make_rate_limit_layer(rate_limit::refresh_limiter(Arc::clone(&proxies)));
    let ticket_limit =
        rate_limit::make_rate_limit_layer(rate_limit::ticket_limiter(Arc::clone(&proxies)));
    let media_upload_limit =
        rate_limit::make_rate_limit_layer(rate_limit::media_upload_limiter(Arc::clone(&proxies)));
    let link_preview_limit =
        rate_limit::make_rate_limit_layer(rate_limit::link_preview_limiter(Arc::clone(&proxies)));
    let key_reset_limit =
        rate_limit::make_rate_limit_layer(rate_limit::key_reset_limiter(Arc::clone(&proxies)));
    let revoke_others_limit =
        rate_limit::make_rate_limit_layer(rate_limit::revoke_others_limiter(proxies));

    let auth_routes = Router::new()
        .route(
            "/register",
            post(auth::register).layer(middleware::from_fn(register_limit)),
        )
        .route(
            "/login",
            post(auth::login).layer(middleware::from_fn(login_limit)),
        )
        .route(
            "/refresh",
            post(auth::refresh).layer(middleware::from_fn(refresh_limit)),
        )
        .route("/logout", post(auth::logout))
        .route(
            "/ws-ticket",
            post(auth::ws_ticket).layer(middleware::from_fn(ticket_limit)),
        );

    let contact_routes = Router::new()
        .route("/", get(contacts::list_contacts))
        .route("/request", post(contacts::send_request))
        .route("/accept", post(contacts::accept_request))
        .route("/decline", post(contacts::decline_request))
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
            "/conversations/{conversation_id}/leave",
            post(messages::leave_conversation),
        )
        .route(
            "/conversations/{conversation_id}/mute",
            put(messages::toggle_mute),
        )
        .route(
            "/conversations/{conversation_id}/pinned",
            get(messages::get_pinned_messages),
        )
        .route(
            "/conversations/{conversation_id}/disappearing",
            put(messages::set_disappearing_ttl),
        )
        .route(
            "/conversations/{conversation_id}/messages/{message_id}/pin",
            post(messages::pin_message).delete(messages::unpin_message),
        )
        .route(
            "/conversations/{conversation_id}/pin",
            put(messages::pin_conversation).delete(messages::unpin_conversation),
        )
        .route("/messages/search", get(messages::search_messages_global))
        .route(
            "/messages/{id}",
            get(messages::get_messages)
                .delete(messages::delete_message)
                .put(messages::edit_message),
        )
        .route("/messages/{id}/replies", get(messages::get_thread_replies))
        .route("/messages/{id}/reactions", post(reactions::add_reaction))
        .route(
            "/messages/{message_id}/reactions/{emoji}",
            delete(reactions::remove_reaction),
        );

    let key_routes = Router::new()
        .route("/upload", post(keys::upload_bundle))
        .route(
            "/reset",
            post(keys::reset_keys).layer(middleware::from_fn(key_reset_limit)),
        )
        .route("/bundle/{user_id}", get(keys::get_bundle))
        .route(
            "/bundle/{user_id}/{device_id}",
            get(keys::get_device_bundle),
        )
        .route("/bundles/{user_id}", get(keys::get_all_bundles))
        // NOTE: register `/devices/revoke-others` BEFORE `/devices/{user_id}`
        // so the static path always wins the route match.
        .route(
            "/devices/revoke-others",
            post(keys::revoke_other_devices).layer(middleware::from_fn(revoke_others_limit)),
        )
        .route("/devices/{user_id}", get(keys::get_devices))
        .route("/device/{device_id}", delete(keys::revoke_device))
        .route("/otp-count", get(keys::get_otp_count));

    let media_routes = Router::new()
        .route(
            "/upload",
            post(media::upload).layer(middleware::from_fn(media_upload_limit)),
        )
        .route("/ticket", post(media::request_media_ticket))
        .route("/{id}", get(media::download))
        .route("/{id}/thumb", get(media::download_thumb))
        .layer(DefaultBodyLimit::max(media::MAX_FILE_SIZE));

    let group_routes = Router::new()
        .route("/", post(groups::create_group))
        .route("/public", get(groups::list_public_groups))
        .route("/{id}/keys", post(group_keys::upload_group_key))
        .route("/{id}/keys/latest", get(group_keys::get_latest_group_key))
        .route(
            "/{id}/keys/{version}",
            get(group_keys::get_group_key_version),
        )
        .route(
            "/{id}/channels",
            get(channels::list_channels).post(channels::create_channel),
        )
        .route(
            "/{id}/channels/{channel_id}",
            put(channels::update_channel).delete(channels::delete_channel),
        )
        .route(
            "/{id}/channels/{channel_id}/canvas",
            get(canvas::get_canvas).delete(canvas::clear_canvas),
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
        .route("/{id}/preview", get(groups::get_group_preview))
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
        .route("/{id}/unban/{user_id}", post(groups::unban_member))
        .route(
            "/{id}/avatar",
            put(groups::upload_group_avatar).get(groups::get_group_avatar),
        );

    let user_routes = Router::new()
        .route("/me", delete(users::delete_account))
        .route("/me/profile", patch(users::update_profile))
        .route("/me/password", patch(users::change_password))
        .route(
            "/me/privacy",
            get(users::get_my_privacy).patch(users::update_my_privacy),
        )
        .route("/me/status", patch(users::update_presence_status))
        .route("/me/status-text", put(users::update_status_text))
        .route("/me/avatar", put(users::upload_avatar))
        .route("/online", get(users::online_users))
        .route("/search", get(users::search_users))
        .route("/resolve/{username}", get(users::resolve_username_invite))
        .route("/{id}/profile", get(users::get_profile))
        .route("/{id}/avatar", get(users::get_avatar));

    let push_routes = Router::new()
        .route("/register", post(push::register_token))
        .route("/unregister", post(push::unregister_token));

    Router::new()
        .nest("/api/auth", auth_routes)
        .nest("/api/contacts", contact_routes)
        .nest("/api/keys", key_routes)
        .nest("/api/groups", group_routes)
        .nest("/api/users", user_routes)
        .nest("/api/media", media_routes)
        .nest("/api/push", push_routes)
        .nest("/api", message_routes)
        .route("/api/voice/token", post(voice::generate_token))
        .route(
            "/api/link-preview",
            post(link_preview::fetch_preview).layer(middleware::from_fn(link_preview_limit)),
        )
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
            header::HeaderName::from_static("referrer-policy"),
            header::HeaderValue::from_static("no-referrer"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::HeaderName::from_static("permissions-policy"),
            header::HeaderValue::from_static("camera=(), microphone=(), geolocation=()"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::STRICT_TRANSPORT_SECURITY,
            header::HeaderValue::from_static("max-age=31536000; includeSubDomains"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::CONTENT_SECURITY_POLICY,
            // API responses are JSON only -- no HTML, scripts, or styles are
            // ever rendered from these endpoints. Lock everything down; the
            // Flutter web client is served by nginx with its own CSP.
            header::HeaderValue::from_static(
                "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
            ),
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
/// Requires authentication to prevent unauthenticated access.
/// Set TURN_URL, TURN_USERNAME, TURN_CREDENTIAL to configure TURN.
pub async fn ice_config(_auth: crate::auth::middleware::AuthUser) -> impl IntoResponse {
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
