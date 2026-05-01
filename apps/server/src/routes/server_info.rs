//! Public server-identity endpoint.
//!
//! `GET /api/server-info` returns metadata used by clients to pin a server
//! across hostname changes and to pre-flight a self-hosted URL before
//! committing to a switch.  Response is intentionally small and unauthenticated
//! (no PII, no enumeration risk).

use axum::Json;
use axum::extract::State;
use axum::response::IntoResponse;
use serde::Serialize;
use std::sync::Arc;

use crate::config::registration_open;
use crate::error::{AppError, DbErrCtx};
use crate::routes::AppState;

#[derive(Debug, Serialize)]
pub struct ServerInfoResponse {
    pub name: &'static str,
    pub version: &'static str,
    pub server_id: String,
    pub registration_open: bool,
    pub federation_capable: bool,
}

/// Return server identity. Mints a row in `server_metadata` on first call
/// and reads it back on every subsequent request, so the UUID is stable
/// across restarts and across requests.
pub async fn server_info(
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    // Singleton bootstrap. Two concurrent first-boot requests both attempt
    // an INSERT but the UNIQUE PRIMARY KEY on `singleton` causes one of
    // them to no-op via ON CONFLICT, so the row's `id` stays stable across
    // every subsequent SELECT. ON CONFLICT DO NOTHING guarantees idempotent
    // success even when our INSERT lost the race -- we follow up with a
    // SELECT to read back whichever row won.
    sqlx::query("INSERT INTO server_metadata (singleton) VALUES (TRUE) ON CONFLICT DO NOTHING")
        .execute(&state.pool)
        .await
        .db_ctx("server_info/insert_singleton")?;

    let (server_id,): (uuid::Uuid,) =
        sqlx::query_as("SELECT id FROM server_metadata WHERE singleton = TRUE LIMIT 1")
            .fetch_one(&state.pool)
            .await
            .db_ctx("server_info/fetch_id")?;

    Ok(Json(ServerInfoResponse {
        name: env!("CARGO_PKG_NAME"),
        version: env!("CARGO_PKG_VERSION"),
        server_id: server_id.to_string(),
        registration_open: registration_open(),
        federation_capable: false,
    }))
}
