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
    // Atomically remove and validate the ticket in a single DashMap operation.
    // This eliminates the TOCTOU race between retain() and remove().
    let now = Instant::now();
    let (user_id, device_id) = {
        let entry = state
            .ticket_store
            .remove_if(&params.ticket, |_, (_, _, created_at)| {
                now.duration_since(*created_at) < TICKET_TTL
            });
        match entry {
            Some((_, (uid, did, _))) => (uid, did),
            None => {
                // Opportunistic cleanup of other expired tickets
                state
                    .ticket_store
                    .retain(|_, (_, _, ts)| now.duration_since(*ts) < TICKET_TTL);
                return Err(AppError::unauthorized(
                    "Invalid or expired WebSocket ticket",
                ));
            }
        }
    };

    let user = db::users::find_by_id(&state.pool, user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in ws_upgrade/find_user: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("User not found"))?;

    tracing::info!(
        "WebSocket connecting: {} ({}) device={}",
        user.username,
        user_id,
        device_id
    );

    Ok(ws.on_upgrade(move |socket| {
        handler::handle_socket(socket, user_id, device_id, user.username, state)
    }))
}
