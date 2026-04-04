//! WebSocket upgrade endpoint using single-use ticket authentication.

use axum::{
    extract::{Query, State, ws::WebSocketUpgrade},
    response::IntoResponse,
};
use serde::Deserialize;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::db;
use crate::error::AppError;
use crate::ws::handler;

use super::AppState;

/// Ticket validity window.
const TICKET_TTL: Duration = Duration::from_secs(30);

#[derive(Deserialize)]
pub struct WsParams {
    pub ticket: String,
}

pub async fn ws_upgrade(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
    Query(params): Query<WsParams>,
) -> Result<impl IntoResponse, AppError> {
    // Look up and consume the ticket (single-use).
    let (user_id, created_at) = {
        let mut store = state
            .ticket_store
            .lock()
            .map_err(|_| AppError::internal("Internal state error"))?;

        // Opportunistic cleanup of expired tickets.
        let now = Instant::now();
        store.retain(|_, (_, ts)| now.duration_since(*ts) < TICKET_TTL);

        store
            .remove(&params.ticket)
            .ok_or_else(|| AppError::unauthorized("Invalid or expired WebSocket ticket"))?
    };

    // Verify the ticket hasn't expired (belt-and-suspenders after cleanup).
    if Instant::now().duration_since(created_at) >= TICKET_TTL {
        return Err(AppError::unauthorized(
            "Invalid or expired WebSocket ticket",
        ));
    }

    let user = db::users::find_by_id(&state.pool, user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ws_upgrade/find_user: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("User not found"))?;

    tracing::info!("WebSocket connecting: {} ({})", user.username, user_id);

    Ok(ws.on_upgrade(move |socket| handler::handle_socket(socket, user_id, user.username, state)))
}
