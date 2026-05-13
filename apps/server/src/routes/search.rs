//! Universal search endpoint.
//!
//! GET /api/search?q=<query>&limit=<n>
//!
//! Returns messages, contacts, and groups matching the query in one response.
//! The three DB queries run concurrently via tokio::try_join!.

use std::sync::Arc;

use axum::Json;
use axum::extract::{Query, State};
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx};

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct UniversalSearchQuery {
    pub q: String,
    #[serde(default = "default_limit")]
    pub limit: i64,
}

fn default_limit() -> i64 {
    15
}

#[derive(Debug, Serialize)]
pub struct UniversalSearchResponse {
    pub messages: Vec<db::messages::GlobalSearchResult>,
    pub contacts: Vec<db::contacts::ContactSearchResult>,
    pub groups: Vec<db::groups::GroupSearchResult>,
}

/// GET /api/search -- universal search across messages, contacts, and groups.
///
/// Messages are full-text searched across all conversations the user is a
/// member of (non-encrypted only -- encrypted DM ciphertext is opaque to
/// the server). Contacts are searched by username and display_name among
/// the caller's accepted contacts. Groups are searched by title among
/// groups the caller is an active member of.
pub async fn universal_search(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Query(params): Query<UniversalSearchQuery>,
) -> Result<impl IntoResponse, AppError> {
    let q = params.q.trim();
    if q.is_empty() {
        return Err(AppError::bad_request("Search query cannot be empty"));
    }
    let limit = params.limit.clamp(1, 25);

    let (messages, contacts, groups) = tokio::try_join!(
        db::messages::search_messages_global(&state.pool, auth.user_id, q, limit),
        db::contacts::search_contacts(&state.pool, auth.user_id, q, limit),
        db::groups::search_user_groups(&state.pool, auth.user_id, q, limit),
    )
    .db_ctx("universal_search")?;

    Ok(Json(UniversalSearchResponse {
        messages,
        contacts,
        groups,
    }))
}
