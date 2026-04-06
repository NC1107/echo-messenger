//! Group encryption key REST endpoints.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;
use crate::types::Role;

use super::AppState;

// -------------------------------------------------------------------------
// Request / response types
// -------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct UploadGroupKeyRequest {
    /// Base64-encoded encrypted group key material.
    pub encrypted_key: String,
    /// The version number for this key (must be higher than any existing).
    pub key_version: i32,
}

#[derive(Debug, Serialize)]
pub struct GroupKeyResponse {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub key_version: i32,
    pub encrypted_key: String,
    pub created_by: Uuid,
    pub created_at: String,
}

impl GroupKeyResponse {
    fn from_row(row: db::keys::GroupKeyRow) -> Self {
        Self {
            id: row.id,
            conversation_id: row.conversation_id,
            key_version: row.key_version,
            encrypted_key: row.encrypted_key,
            created_by: row.created_by,
            created_at: row.created_at.to_rfc3339(),
        }
    }
}

// -------------------------------------------------------------------------
// POST /api/groups/:id/keys -- Upload a new group key (owner/admin only)
// -------------------------------------------------------------------------

pub async fn upload_group_key(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    Json(body): Json<UploadGroupKeyRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Verify membership and role
    let role_str = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in upload_group_key/get_role: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::unauthorized("Not a member of this group"))?;

    let role = Role::from_str_opt(&role_str).unwrap_or(Role::Member);
    if !role.is_admin_or_above() {
        return Err(AppError::unauthorized(
            "Only admins and owners can upload group keys",
        ));
    }

    if body.encrypted_key.is_empty() {
        return Err(AppError::bad_request("encrypted_key cannot be empty"));
    }
    if body.key_version < 1 {
        return Err(AppError::bad_request(
            "key_version must be a positive integer",
        ));
    }

    let row = db::keys::store_group_key(
        &state.pool,
        group_id,
        body.key_version,
        &body.encrypted_key,
        auth.user_id,
    )
    .await
    .map_err(|e| match &e {
        sqlx::Error::Database(db_err) if db_err.code().as_deref() == Some("23505") => {
            AppError::conflict("A group key with this version already exists")
        }
        _ => {
            tracing::error!("DB error in upload_group_key/store: {e:?}");
            AppError::internal("Failed to store group key")
        }
    })?;

    // Broadcast key_rotated event to all group members
    let member_ids = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();

    let event = serde_json::json!({
        "type": "group_key_rotated",
        "conversation_id": group_id,
        "key_version": row.key_version,
        "created_by": auth.user_id,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        use axum::extract::ws::Message as WsMessage;
        state
            .hub
            .broadcast_json(&member_ids, &json, Some(auth.user_id));
        // Also notify the uploader so their client caches the new version
        state
            .hub
            .send_to(&auth.user_id, WsMessage::Text(json.into()));
    }

    Ok((StatusCode::CREATED, Json(GroupKeyResponse::from_row(row))))
}

// -------------------------------------------------------------------------
// GET /api/groups/:id/keys/latest -- Get latest group key
// -------------------------------------------------------------------------

pub async fn get_latest_group_key(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_latest_group_key/is_member: {e:?}");
            AppError::internal("Database error")
        })?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    let row = db::keys::get_latest_group_key(&state.pool, group_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_latest_group_key/fetch: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("No group key found for this conversation"))?;

    Ok(Json(GroupKeyResponse::from_row(row)))
}

// -------------------------------------------------------------------------
// GET /api/groups/:id/keys/:version -- Get a specific group key version
// -------------------------------------------------------------------------

pub async fn get_group_key_version(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, version)): Path<(Uuid, i32)>,
) -> Result<impl IntoResponse, AppError> {
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_group_key_version/is_member: {e:?}");
            AppError::internal("Database error")
        })?;

    if !is_member {
        return Err(AppError::unauthorized("Not a member of this group"));
    }

    let row = db::keys::get_group_key(&state.pool, group_id, version)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_group_key_version/fetch: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("Group key version not found"))?;

    Ok(Json(GroupKeyResponse::from_row(row)))
}
