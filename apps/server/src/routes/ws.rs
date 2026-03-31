//! WebSocket upgrade endpoint.

use axum::{
    extract::{Query, State, ws::WebSocketUpgrade},
    response::IntoResponse,
};
use serde::Deserialize;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::jwt;
use crate::db;
use crate::error::AppError;
use crate::ws::handler;

use super::AppState;

#[derive(Deserialize)]
pub struct WsParams {
    pub token: String,
}

pub async fn ws_upgrade(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
    Query(params): Query<WsParams>,
) -> Result<impl IntoResponse, AppError> {
    let claims = jwt::validate_token(&params.token, &state.jwt_secret)?;
    let user_id =
        Uuid::parse_str(&claims.sub).map_err(|_| AppError::unauthorized("Invalid token"))?;

    let user = db::users::find_by_id(&state.pool, user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::unauthorized("User not found"))?;

    tracing::info!("WebSocket connecting: {} ({})", user.username, user_id);

    Ok(ws.on_upgrade(move |socket| handler::handle_socket(socket, user_id, user.username, state)))
}
