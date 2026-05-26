//! Beta feedback endpoint.
//!
//! `POST /api/feedback` lets a logged-in user file a single bug-report /
//! feature-request row.  Reports land in the `feedback` table where the
//! operator reads them via `/api/admin/feedback` (see `routes::admin`).
//!
//! The 5-per-24h rate limit is enforced by counting recent rows for the
//! caller before insert; in-memory limiter (used elsewhere) would reset on
//! restart and burn anonymous quota across users that share an IP, neither
//! of which we want for an authenticated abuse-prevention gate.

use std::sync::Arc;

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};

use crate::auth::middleware::AuthUser;
use crate::error::{AppError, DbErrCtx};
use crate::routes::AppState;

/// Hard caps on user-supplied free text so a malicious or buggy client can't
/// fill the table with megabyte-sized rows.
const MAX_TITLE_CHARS: usize = 100;
const MAX_BODY_CHARS: usize = 4_000;
const MAX_LOGS_CHARS: usize = 32_000;

/// How many open/closed/triaged reports a single user may file per rolling
/// 24-hour window.  Generous enough that a tester pasting 4 follow-ups in a
/// row still goes through; tight enough that a runaway script can't flood
/// the inbox.
const RATE_LIMIT_PER_24H: i64 = 5;

#[derive(Debug, Deserialize)]
pub struct CreateFeedbackRequest {
    pub title: String,
    pub body: String,
    #[serde(default)]
    pub public_ok: bool,
    #[serde(default)]
    pub app_version: Option<String>,
    #[serde(default)]
    pub platform: Option<String>,
    #[serde(default)]
    pub logs: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateFeedbackResponse {
    pub feedback_id: String,
}

pub async fn create_feedback(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Json(req): Json<CreateFeedbackRequest>,
) -> Result<impl IntoResponse, AppError> {
    let title = req.title.trim();
    let body = req.body.trim();

    if title.is_empty() {
        return Err(AppError::bad_request("Title is required"));
    }
    if body.is_empty() {
        return Err(AppError::bad_request("Body is required"));
    }
    if title.chars().count() > MAX_TITLE_CHARS {
        return Err(AppError::bad_request(format!(
            "Title must be {MAX_TITLE_CHARS} characters or fewer"
        )));
    }
    if body.chars().count() > MAX_BODY_CHARS {
        return Err(AppError::bad_request(format!(
            "Body must be {MAX_BODY_CHARS} characters or fewer"
        )));
    }

    // Trim diagnostic context fields; empty-after-trim becomes None so we
    // don't pollute the table with whitespace-only rows.
    let clean_opt = |s: &Option<String>| -> Option<String> {
        s.as_ref()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let app_version = clean_opt(&req.app_version);
    let platform = clean_opt(&req.platform);
    let logs = clean_opt(&req.logs);

    if let Some(ref l) = logs
        && l.chars().count() > MAX_LOGS_CHARS
    {
        return Err(AppError::bad_request(format!(
            "Logs must be {MAX_LOGS_CHARS} characters or fewer"
        )));
    }

    // Count includes triaged/closed so closing a report can't refill quota.
    let (recent,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM feedback \
         WHERE user_id = $1 AND created_at > NOW() - INTERVAL '24 hours'",
    )
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await
    .db_ctx("feedback/rate_limit_count")?;

    if recent >= RATE_LIMIT_PER_24H {
        return Err(AppError {
            status: StatusCode::TOO_MANY_REQUESTS,
            message: format!(
                "You've sent {RATE_LIMIT_PER_24H} reports in the last 24h. Please wait before sending more."
            ),
            code: crate::error::ErrorCode::RateLimited,
            body: None,
        });
    }

    let (id,): (uuid::Uuid,) = sqlx::query_as(
        "INSERT INTO feedback (user_id, title, body, public_ok, app_version, platform, logs) \
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
    )
    .bind(auth.user_id)
    .bind(title)
    .bind(body)
    .bind(req.public_ok)
    .bind(app_version)
    .bind(platform)
    .bind(logs)
    .fetch_one(&state.pool)
    .await
    .db_ctx("feedback/insert")?;

    Ok((
        StatusCode::CREATED,
        Json(CreateFeedbackResponse {
            feedback_id: id.to_string(),
        }),
    ))
}
