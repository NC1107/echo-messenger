//! Operator-only admin endpoints.
//!
//! Gated by an `AdminUser` extractor that wraps `AuthUser` and additionally
//! requires `users.is_admin = TRUE`.  Promotion is a manual `UPDATE` the
//! operator runs against the DB (see `docs/dev-environment.md`); we
//! deliberately don't expose a "make me admin" API.

use std::sync::Arc;

use axum::Json;
use axum::extract::{FromRequestParts, Query, State};
use axum::http::request::Parts;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};

use crate::auth::middleware::AuthUser;
use crate::error::{AppError, DbErrCtx};
use crate::routes::AppState;

/// Extractor that resolves a JWT to a user and then short-circuits with 403
/// unless `users.is_admin` is TRUE.  Implemented on top of [`AuthUser`] so
/// the underlying token validation stays in one place.
pub struct AdminUser {
    #[allow(dead_code)]
    pub user_id: uuid::Uuid,
}

impl FromRequestParts<Arc<AppState>> for AdminUser {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let auth = AuthUser::from_request_parts(parts, state).await?;
        let (is_admin,): (bool,) = sqlx::query_as("SELECT is_admin FROM users WHERE id = $1")
            .bind(auth.user_id)
            .fetch_one(&state.pool)
            .await
            .db_ctx("admin/is_admin_lookup")?;
        if !is_admin {
            return Err(AppError::forbidden("Admin access required"));
        }
        Ok(AdminUser {
            user_id: auth.user_id,
        })
    }
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
    // One round trip per metric keeps the SQL readable.  All seven scans
    // hit indexed columns (`identity_keys.last_seen`, `messages.created_at`,
    // `feedback.status` / `created_at`) so even on a busy server the
    // dashboard load stays cheap; we can fold this into one CTE later if
    // it shows up in slow-query logs.
    let (users_total,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users")
        .fetch_one(&state.pool)
        .await
        .db_ctx("admin/users_total")?;

    // "Active in last 24h" approximates presence via the MAX(last_seen)
    // across each user's device fingerprints in `identity_keys`. That's
    // the column the WS hub bumps on every connect (`update_last_seen`
    // in `db::keys`). Users with no devices fall back to `created_at`
    // so brand-new sign-ups still count for the first 24h.
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

    // Hub-level counter: the WS hub keeps one DashMap entry per connected
    // device, but we can't reach that map from a thread-state extractor
    // without lifetime gymnastics.  Use the DB's view instead -- it
    // approximates "currently online" via identity_keys.last_seen within
    // the last 90 seconds.
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
    // Whitelist status values to keep the predicate sargable against the
    // `feedback_status_created_at_idx` index.  Anything else 400s rather
    // than silently returning an empty page.
    if !matches!(q.status.as_str(), "open" | "triaged" | "closed") {
        return Err(AppError::bad_request(
            "status must be one of: open, triaged, closed",
        ));
    }
    let limit = q.limit.clamp(1, 200);

    let rows: Vec<(
        uuid::Uuid,
        uuid::Uuid,
        Option<String>,
        String,
        String,
        bool,
        String,
        chrono::DateTime<chrono::Utc>,
    )> = sqlx::query_as(
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
