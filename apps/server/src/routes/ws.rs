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

#[cfg(test)]
mod tests {
    use super::*;
    use dashmap::DashMap;
    use uuid::Uuid;

    type TestTicketStore = DashMap<String, (Uuid, i32, Instant)>;

    #[test]
    fn test_ticket_single_use() {
        let store: TestTicketStore = DashMap::new();
        let uid = Uuid::new_v4();
        let ticket = "test-ticket-123".to_string();
        store.insert(ticket.clone(), (uid, 1, Instant::now()));

        // First use succeeds
        let now = Instant::now();
        let first = store.remove_if(&ticket, |_, (_, _, created_at)| {
            now.duration_since(*created_at) < TICKET_TTL
        });
        assert!(first.is_some(), "first use should succeed");

        // Second use fails (ticket consumed)
        let second = store.remove_if(&ticket, |_, (_, _, created_at)| {
            now.duration_since(*created_at) < TICKET_TTL
        });
        assert!(second.is_none(), "replay should fail");
    }

    #[test]
    fn test_ticket_expired() {
        let store: TestTicketStore = DashMap::new();
        let uid = Uuid::new_v4();
        let ticket = "expired-ticket".to_string();
        // Insert with a timestamp 60 seconds in the past
        let old = Instant::now() - Duration::from_secs(60);
        store.insert(ticket.clone(), (uid, 1, old));

        let now = Instant::now();
        let result = store.remove_if(&ticket, |_, (_, _, created_at)| {
            now.duration_since(*created_at) < TICKET_TTL
        });
        assert!(result.is_none(), "expired ticket should be rejected");
        // Ticket still in store (not removed because condition was false)
        assert!(store.contains_key(&ticket));
    }

    #[test]
    fn test_ticket_invalid() {
        let store: TestTicketStore = DashMap::new();
        let result = store.remove_if("nonexistent", |_, (_, _, created_at)| {
            Instant::now().duration_since(*created_at) < TICKET_TTL
        });
        assert!(result.is_none(), "invalid ticket should be rejected");
    }

    #[test]
    fn test_ticket_returns_correct_user() {
        let store: TestTicketStore = DashMap::new();
        let uid = Uuid::new_v4();
        let device_id = 42;
        store.insert("my-ticket".to_string(), (uid, device_id, Instant::now()));

        let now = Instant::now();
        let (_, (returned_uid, returned_did, _)) = store
            .remove_if("my-ticket", |_, (_, _, created_at)| {
                now.duration_since(*created_at) < TICKET_TTL
            })
            .unwrap();
        assert_eq!(returned_uid, uid);
        assert_eq!(returned_did, device_id);
    }
}
