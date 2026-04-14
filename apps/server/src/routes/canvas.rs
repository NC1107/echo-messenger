//! REST endpoints for the voice-lounge canvas.
//!
//! GET  /api/groups/{id}/channels/{channel_id}/canvas
//!   → Returns the current persistent canvas state (drawing strokes + images).
//!     Both arrays use normalized coordinates (0–1) so the layout scales
//!     across different screen sizes.
//!
//! DELETE /api/groups/{id}/channels/{channel_id}/canvas
//!   → Clears drawing strokes and images (requires at least member role;
//!     any member can reset the shared board).

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use serde::Serialize;
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

#[derive(Debug, Serialize)]
pub struct CanvasResponse {
    pub channel_id: Uuid,
    pub drawing_data: serde_json::Value,
    pub images_data: serde_json::Value,
}

/// GET /api/groups/:id/channels/:channel_id/canvas
pub async fn get_canvas(
    auth: AuthUser,
    state: State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
) -> Result<Json<CanvasResponse>, AppError> {
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;
    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    // Verify the channel belongs to this group.
    let channel = db::channels::get_channel(&state.pool, channel_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::bad_request("Channel not found"))?;
    if channel.conversation_id != group_id {
        return Err(AppError::bad_request(
            "Channel does not belong to this group",
        ));
    }

    let row = db::canvas::get(&state.pool, channel_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok(Json(CanvasResponse {
        channel_id: row.channel_id,
        drawing_data: row.drawing_data,
        images_data: row.images_data,
    }))
}

/// DELETE /api/groups/:id/channels/:channel_id/canvas
///
/// Any member can wipe the board.  This is intentional — the canvas is a
/// shared collaborative space (like a physical whiteboard in a meeting room).
/// Restricting resets to admins only would frustrate the collaborative
/// purpose; if needed, role-based gating can be added later.
pub async fn clear_canvas(
    auth: AuthUser,
    state: State<Arc<AppState>>,
    Path((group_id, channel_id)): Path<(Uuid, Uuid)>,
) -> Result<StatusCode, AppError> {
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;
    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    let channel = db::channels::get_channel(&state.pool, channel_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::bad_request("Channel not found"))?;
    if channel.conversation_id != group_id {
        return Err(AppError::bad_request(
            "Channel does not belong to this group",
        ));
    }

    db::canvas::clear_all(&state.pool, channel_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    Ok(StatusCode::NO_CONTENT)
}
