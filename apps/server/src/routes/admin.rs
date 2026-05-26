//! Operator-only admin endpoints.
//!
//! Gated by an `AdminUser` extractor that wraps `AuthUser` and additionally
//! requires `users.is_admin = TRUE`.  Promotion is a manual `UPDATE` the
//! operator runs against the DB (see `docs/dev-environment.md`); we
//! deliberately don't expose a "make me admin" API.

use std::sync::Arc;

use axum::Json;
use axum::extract::{FromRequestParts, Path, Query, State};
use axum::http::request::Parts;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};

use crate::auth::jwt;
use crate::auth::middleware::AuthUser;
use crate::error::{AppError, DbErrCtx};
use crate::routes::AppState;

/// Window during which a freshly-issued JWT is considered "warm" enough to
/// access admin routes. Five minutes lets an operator chain a handful of
/// dashboard refreshes off one re-auth without keeping the elevated
/// session indefinitely. When `iat` is older than this the response
/// includes `WWW-Authenticate: Bearer error="reauth_required"` so the
/// client knows to prompt for the password again.
const ADMIN_REAUTH_WINDOW_SECS: i64 = 5 * 60;

/// Extractor that resolves a JWT to a user and then short-circuits with 403
/// unless `users.is_admin` is TRUE.  Implemented on top of [`AuthUser`] so
/// the underlying token validation stays in one place.
pub struct AdminUser {
    #[allow(dead_code)]
    pub user_id: uuid::Uuid,
}

impl FromRequestParts<Arc<AppState>> for AdminUser {
    type Rejection = Response;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let auth = AuthUser::from_request_parts(parts, state)
            .await
            .map_err(IntoResponse::into_response)?;

        let (is_admin,): (bool,) = sqlx::query_as("SELECT is_admin FROM users WHERE id = $1")
            .bind(auth.user_id)
            .fetch_one(&state.pool)
            .await
            .db_ctx("admin/is_admin_lookup")
            .map_err(IntoResponse::into_response)?;
        if !is_admin {
            return Err(AppError::forbidden("Admin access required").into_response());
        }

        // Admin endpoints require a recent token; stale → 401 reauth_required.
        if !admin_token_is_fresh(parts, &state.jwt_secret) {
            return Err(reauth_required_response());
        }

        Ok(AdminUser {
            user_id: auth.user_id,
        })
    }
}

/// Returns `true` when the bearer token's `iat` is within
/// [`ADMIN_REAUTH_WINDOW_SECS`] seconds of now. Absence of a token or any
/// decode failure flips this to `false` — the surrounding [`AuthUser`]
/// already rejected the request if the token was actually invalid, so the
/// only realistic path into the `false` branch is a valid-but-stale token.
fn admin_token_is_fresh(parts: &Parts, secret: &str) -> bool {
    let Some(token) = parts
        .headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    else {
        return false;
    };
    let Ok(claims) = jwt::validate_token(token, secret) else {
        return false;
    };
    let now = chrono::Utc::now().timestamp();
    let iat = claims.iat as i64;
    (now - iat) <= ADMIN_REAUTH_WINDOW_SECS
}

fn reauth_required_response() -> Response {
    let body = serde_json::json!({
        "error": "Admin session is stale — please re-authenticate",
        "code": "reauth-required",
    });
    let mut resp = (StatusCode::UNAUTHORIZED, Json(body)).into_response();
    resp.headers_mut().insert(
        header::WWW_AUTHENTICATE,
        HeaderValue::from_static("Bearer error=\"reauth_required\""),
    );
    resp
}

#[derive(Debug, Serialize)]
pub struct AdminStats {
    pub users_total: i64,
    pub users_active_24h: i64,
    pub messages_24h: i64,
    pub groups_total: i64,
    pub online_devices: i64,
    pub feedback_open: i64,
    pub feedback_last_24h: i64,
}

pub async fn get_stats(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
) -> Result<impl IntoResponse, AppError> {
    // One query per metric — all hit indexed columns; fold into a CTE later
    // if it shows up in slow-query logs.
    let (users_total,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users")
        .fetch_one(&state.pool)
        .await
        .db_ctx("admin/users_total")?;

    // Presence via MAX(identity_keys.last_seen); brand-new users with no
    // devices fall back to `created_at` so they still count for 24h.
    let (users_active_24h,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM users u \
         WHERE COALESCE( \
                 (SELECT MAX(ik.last_seen) FROM identity_keys ik \
                  WHERE ik.user_id = u.id), \
                 u.created_at \
               ) > NOW() - INTERVAL '24 hours'",
    )
    .fetch_one(&state.pool)
    .await
    .db_ctx("admin/users_active_24h")?;

    let (messages_24h,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM messages WHERE created_at > NOW() - INTERVAL '24 hours'",
    )
    .fetch_one(&state.pool)
    .await
    .db_ctx("admin/messages_24h")?;

    let (groups_total,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM conversations WHERE kind = 'group'")
            .fetch_one(&state.pool)
            .await
            .db_ctx("admin/groups_total")?;

    // DB approximation of "online" (last 90s) since reaching the hub DashMap
    // from a state extractor needs lifetime gymnastics.
    let (online_devices,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM identity_keys \
         WHERE last_seen > NOW() - INTERVAL '90 seconds'",
    )
    .fetch_one(&state.pool)
    .await
    .db_ctx("admin/online_devices")?;

    let (feedback_open,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM feedback WHERE status = 'open'")
            .fetch_one(&state.pool)
            .await
            .db_ctx("admin/feedback_open")?;

    let (feedback_last_24h,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM feedback WHERE created_at > NOW() - INTERVAL '24 hours'",
    )
    .fetch_one(&state.pool)
    .await
    .db_ctx("admin/feedback_last_24h")?;

    Ok(Json(AdminStats {
        users_total,
        users_active_24h,
        messages_24h,
        groups_total,
        online_devices,
        feedback_open,
        feedback_last_24h,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ListFeedbackQuery {
    #[serde(default = "default_status")]
    pub status: String,
    #[serde(default = "default_limit")]
    pub limit: i64,
}

fn default_status() -> String {
    "open".to_string()
}

fn default_limit() -> i64 {
    50
}

#[derive(Debug, Serialize)]
pub struct FeedbackRow {
    pub id: String,
    pub user_id: String,
    pub username: Option<String>,
    pub title: String,
    pub body: String,
    pub public_ok: bool,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

pub async fn list_feedback(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Query(q): Query<ListFeedbackQuery>,
) -> Result<impl IntoResponse, AppError> {
    // Whitelist keeps the predicate sargable against the status index.
    if !matches!(q.status.as_str(), "open" | "triaged" | "closed") {
        return Err(AppError::bad_request(
            "status must be one of: open, triaged, closed",
        ));
    }
    let limit = q.limit.clamp(1, 200);

    // Wrap the wide row tuple in a typedef so clippy::type_complexity is
    // satisfied without an `#[allow]`.
    type Row = (
        uuid::Uuid,
        uuid::Uuid,
        Option<String>,
        String,
        String,
        bool,
        String,
        chrono::DateTime<chrono::Utc>,
    );
    let rows: Vec<Row> = sqlx::query_as(
        "SELECT f.id, f.user_id, u.username, f.title, f.body, f.public_ok, f.status, f.created_at \
         FROM feedback f LEFT JOIN users u ON u.id = f.user_id \
         WHERE f.status = $1 \
         ORDER BY f.created_at DESC \
         LIMIT $2",
    )
    .bind(&q.status)
    .bind(limit)
    .fetch_all(&state.pool)
    .await
    .db_ctx("admin/list_feedback")?;

    let payload: Vec<FeedbackRow> = rows
        .into_iter()
        .map(
            |(id, user_id, username, title, body, public_ok, status, created_at)| FeedbackRow {
                id: id.to_string(),
                user_id: user_id.to_string(),
                username,
                title,
                body,
                public_ok,
                status,
                created_at,
            },
        )
        .collect();

    Ok(Json(serde_json::json!({ "feedback": payload })))
}

// ---------------------------------------------------------------------------
// Realtime dashboard (#681 Phase 1)
// ---------------------------------------------------------------------------

/// Aggregated, privacy-safe operator metrics polled by the admin dashboard.
///
/// **Privacy invariant**: no message content, no decrypted previews, no
/// per-user-conversation identification.  Everything below is either a
/// process-level counter or a server-wide aggregate.
#[derive(Debug, Serialize)]
pub struct RealtimeStats {
    /// Distinct user_ids currently registered in the WS hub.
    pub connected_sessions: u64,
    /// Per-platform breakdown of [`Self::connected_sessions`].  The current
    /// WS upgrade path doesn't capture the client platform, so everyone
    /// lands in `unknown` for now (Phase 1 — wiring TBD in #681 Phase 2).
    pub connected_sessions_by_platform: PlatformBreakdown,
    /// Sliding 60s window: messages successfully relayed per second.
    pub messages_per_sec: f64,
    /// Distinct conversation_ids with at least one active voice session.
    /// Sourced from the existing `voice_sessions` table; no LiveKit-specific
    /// data is exposed.
    pub active_voice_rooms: u32,
    /// In-flight DB connections (`size - num_idle`).
    pub db_pool_in_flight: u32,
    /// Configured pool ceiling.
    pub db_pool_max: u32,
}

#[derive(Debug, Default, Serialize)]
pub struct PlatformBreakdown {
    pub web: u64,
    pub mobile: u64,
    pub desktop: u64,
    /// Where every session lands today — the WS handshake doesn't carry a
    /// platform field yet. Documented as TBD in #681 Phase 2 so we don't
    /// fake numbers (the privacy invariant cuts both ways: we won't
    /// fabricate observability either).
    pub unknown: u64,
}

pub async fn get_realtime_stats(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
) -> Result<impl IntoResponse, AppError> {
    let online_user_ids = state.hub.get_online_user_ids();
    let connected_sessions = online_user_ids.len() as u64;
    let connected_sessions_by_platform = PlatformBreakdown {
        // TODO(#681 Phase 2): wire WS handshake `X-Echo-Platform` header
        // into the hub so we can split this honestly.  Until then, every
        // session reports as `unknown` — the dashboard renders that
        // bucket explicitly so an operator can see the gap.
        unknown: connected_sessions,
        ..PlatformBreakdown::default()
    };

    let messages_per_sec = state.message_rate.per_second();

    let (active_voice_rooms,): (i64,) = sqlx::query_as(
        // Voice sessions hang off a channel, which hangs off a conversation.
        // Distinct conversations = distinct active voice rooms.
        "SELECT COUNT(DISTINCT c.conversation_id) \
         FROM voice_sessions vs \
         JOIN channels c ON c.id = vs.channel_id",
    )
    .fetch_one(&state.pool)
    .await
    .db_ctx("admin/realtime_voice_rooms")?;

    let db_pool_in_flight = state
        .pool
        .size()
        .saturating_sub(state.pool.num_idle() as u32);
    let db_pool_max = state.pool.options().get_max_connections();

    Ok(Json(RealtimeStats {
        connected_sessions,
        connected_sessions_by_platform,
        messages_per_sec,
        active_voice_rooms: u32::try_from(active_voice_rooms.max(0)).unwrap_or(u32::MAX),
        db_pool_in_flight,
        db_pool_max,
    }))
}

// ---------------------------------------------------------------------------
// Promotion (#681 Phase 1)
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct PromotedUser {
    pub id: String,
    pub username: String,
    pub is_admin: bool,
}

/// `POST /api/admin/promote/{user_id}` — make `user_id` an admin.
///
/// Demotion is intentionally not in this PR (#681 Phase 1.5).  404 on
/// missing user, 200 with the updated row (sans password) on success.
pub async fn promote_user(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Path(user_id): Path<uuid::Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let row: Option<(uuid::Uuid, String, bool)> = sqlx::query_as(
        "UPDATE users SET is_admin = TRUE \
         WHERE id = $1 \
         RETURNING id, username, is_admin",
    )
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await
    .db_ctx("admin/promote_user")?;

    let Some((id, username, is_admin)) = row else {
        return Err(AppError::not_found("User not found"));
    };

    Ok(Json(PromotedUser {
        id: id.to_string(),
        username,
        is_admin,
    }))
}
