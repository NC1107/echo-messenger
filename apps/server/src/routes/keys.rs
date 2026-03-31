//! PreKey bundle upload and fetch endpoints.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

/// Request body for uploading a PreKey bundle.
#[derive(Debug, Deserialize)]
pub struct UploadBundleRequest {
    /// Ed25519 identity public key, base64-encoded.
    pub identity_key: String,
    /// X25519 signed prekey, base64-encoded.
    pub signed_prekey: String,
    /// Ed25519 signature over the signed prekey, base64-encoded.
    pub signed_prekey_signature: String,
    /// Numeric ID for the signed prekey.
    pub signed_prekey_id: i32,
    /// List of one-time prekeys: (id, base64-encoded X25519 public key).
    pub one_time_prekeys: Vec<OneTimePreKeyUpload>,
}

#[derive(Debug, Deserialize)]
pub struct OneTimePreKeyUpload {
    pub key_id: i32,
    pub public_key: String,
}

/// Response body when fetching a PreKey bundle.
#[derive(Debug, Serialize)]
pub struct PreKeyBundleResponse {
    pub identity_key: String,
    pub signed_prekey: String,
    pub signed_prekey_signature: String,
    pub signed_prekey_id: i32,
    pub one_time_prekey: Option<OneTimePreKeyResponse>,
}

#[derive(Debug, Serialize)]
pub struct OneTimePreKeyResponse {
    pub key_id: i32,
    pub public_key: String,
}

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;

/// POST /api/keys/upload -- Upload a PreKey bundle for the authenticated user.
pub async fn upload_bundle(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(body): Json<UploadBundleRequest>,
) -> Result<impl IntoResponse, AppError> {
    let identity_key = BASE64
        .decode(&body.identity_key)
        .map_err(|_| AppError::bad_request("Invalid base64 for identity_key"))?;
    let signed_prekey = BASE64
        .decode(&body.signed_prekey)
        .map_err(|_| AppError::bad_request("Invalid base64 for signed_prekey"))?;
    let signed_prekey_signature = BASE64
        .decode(&body.signed_prekey_signature)
        .map_err(|_| AppError::bad_request("Invalid base64 for signed_prekey_signature"))?;

    let one_time_prekeys: Vec<(i32, Vec<u8>)> = body
        .one_time_prekeys
        .iter()
        .map(|otk| {
            let pk = BASE64
                .decode(&otk.public_key)
                .map_err(|_| AppError::bad_request("Invalid base64 for one_time_prekey"))?;
            Ok((otk.key_id, pk))
        })
        .collect::<Result<Vec<_>, AppError>>()?;

    db::keys::store_identity_key(&state.pool, auth_user.user_id, &identity_key).await?;
    db::keys::store_signed_prekey(
        &state.pool,
        auth_user.user_id,
        body.signed_prekey_id,
        &signed_prekey,
        &signed_prekey_signature,
    )
    .await?;

    if !one_time_prekeys.is_empty() {
        db::keys::store_one_time_prekeys(&state.pool, auth_user.user_id, &one_time_prekeys)
            .await?;
    }

    tracing::info!(
        "PreKey bundle uploaded for user {} ({} OTPs)",
        auth_user.user_id,
        one_time_prekeys.len()
    );

    Ok(StatusCode::CREATED)
}

/// GET /api/keys/bundle/:user_id -- Fetch a user's PreKey bundle.
pub async fn get_bundle(
    State(state): State<Arc<AppState>>,
    _auth_user: AuthUser,
    Path(user_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let bundle = db::keys::get_prekey_bundle(&state.pool, user_id)
        .await?
        .ok_or_else(|| AppError::bad_request("No PreKey bundle found for this user"))?;

    let response = PreKeyBundleResponse {
        identity_key: BASE64.encode(&bundle.identity_key),
        signed_prekey: BASE64.encode(&bundle.signed_prekey),
        signed_prekey_signature: BASE64.encode(&bundle.signed_prekey_signature),
        signed_prekey_id: bundle.signed_prekey_id,
        one_time_prekey: bundle.one_time_prekey.map(|otk| OneTimePreKeyResponse {
            key_id: otk.key_id,
            public_key: BASE64.encode(&otk.public_key),
        }),
    };

    Ok(Json(response))
}
