//! PreKey bundle upload and fetch endpoints.

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
    /// Device ID for multi-device support. Defaults to 0 for backward compatibility.
    #[serde(default)]
    pub device_id: i32,
    /// Ed25519 signing public key, base64-encoded. Required to prevent MITM attacks.
    pub signing_key: String,
    /// Optional human-readable platform label (e.g. "iOS", "Linux") written
    /// alongside the identity key so the device-management UI can display it.
    #[serde(default)]
    pub platform: Option<String>,
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
    pub signing_key: String,
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

/// Device info returned in the device list response.
#[derive(Debug, Serialize)]
pub struct DeviceInfo {
    pub device_id: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen: Option<chrono::DateTime<chrono::Utc>>,
}

impl From<db::keys::DeviceRow> for DeviceInfo {
    fn from(row: db::keys::DeviceRow) -> Self {
        DeviceInfo {
            device_id: row.device_id,
            platform: row.platform,
            last_seen: row.last_seen,
        }
    }
}

/// Response body for device list query.
#[derive(Debug, Serialize)]
pub struct DeviceListResponse {
    pub user_id: Uuid,
    pub devices: Vec<DeviceInfo>,
}

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use sha2::{Digest, Sha256};

/// Compute a SHA-256 fingerprint of the identity key + signing key combined.
/// Including the signing key prevents an attacker from silently rotating it
/// while keeping the identity key unchanged.
fn identity_fingerprint(identity_key: &[u8], signing_key: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(identity_key);
    hasher.update(signing_key);
    hasher.finalize().to_vec()
}

/// Extract and base64-encode the signing key from a bundle, rejecting bundles
/// without one (legacy bundles missing a signing key are a MITM risk).
fn require_signing_key(
    bundle: &db::keys::PreKeyBundleRow,
    user_id: Uuid,
) -> Result<String, AppError> {
    bundle
        .signing_key
        .as_ref()
        .map(|sk| BASE64.encode(sk))
        .ok_or_else(|| {
            tracing::warn!(
                "Bundle for user {} has no signing_key -- rejecting (MITM risk)",
                user_id,
            );
            AppError::bad_request("No signing key in bundle; owner must re-upload keys")
        })
}

/// POST /api/keys/upload -- Upload a PreKey bundle for the authenticated user.
pub async fn upload_bundle(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(body): Json<UploadBundleRequest>,
) -> Result<impl IntoResponse, AppError> {
    let identity_key = BASE64
        .decode(&body.identity_key)
        .map_err(|_| AppError::bad_request("Invalid base64 for identity_key"))?;
    if identity_key.len() != 32 {
        return Err(AppError::bad_request(
            "identity_key must be exactly 32 bytes (X25519)",
        ));
    }
    let signed_prekey = BASE64
        .decode(&body.signed_prekey)
        .map_err(|_| AppError::bad_request("Invalid base64 for signed_prekey"))?;
    if signed_prekey.len() != 32 {
        return Err(AppError::bad_request(
            "signed_prekey must be exactly 32 bytes (X25519)",
        ));
    }
    let signed_prekey_signature = BASE64
        .decode(&body.signed_prekey_signature)
        .map_err(|_| AppError::bad_request("Invalid base64 for signed_prekey_signature"))?;

    // Platform label is surfaced in the device management UI; cap its length
    // so a malicious client can't bloat the row with unbounded text.
    if let Some(platform) = body.platform.as_deref()
        && platform.len() > 32
    {
        return Err(AppError::bad_request("platform too long (max 32 chars)"));
    }

    let device_id = body.device_id;

    // Decode and verify signing_key + signature (required for MITM prevention).
    //
    // Proof-of-possession rationale (#74): requiring the client to provide a
    // valid Ed25519 signature over `signed_prekey` bytes using `signing_key`
    // implicitly proves possession of the signing private key -- an attacker
    // that does not hold the private key cannot produce a valid signature.
    // This is equivalent to a challenge-response: the signed_prekey bytes act
    // as the message being signed, and the server verifies the signature with
    // the uploaded public key.  The identity binding fingerprint (stored on
    // first upload, checked on every subsequent upload) further prevents an
    // attacker from swapping the identity key while keeping the signing key or
    // vice-versa.  A separate explicit nonce challenge would add no additional
    // security here because the attacker is already unable to forge the
    // signature without the private key.
    let signing_key_bytes = BASE64
        .decode(&body.signing_key)
        .map_err(|_| AppError::bad_request("Invalid base64 for signing_key"))?;
    verify_signed_prekey_signature(&signing_key_bytes, &signed_prekey, &signed_prekey_signature)?;

    // --- Identity binding check ---
    // On first upload the identity+signing key fingerprint is stored on the
    // user row. On subsequent uploads the keys MUST match or the request is
    // rejected with 409. Rotation requires POST /api/keys/reset.
    let new_fingerprint = identity_fingerprint(&identity_key, &signing_key_bytes);
    let stored_fingerprint =
        db::keys::get_identity_key_fingerprint(&state.pool, auth_user.user_id).await?;
    match stored_fingerprint {
        Some(ref existing) if *existing != new_fingerprint => {
            tracing::warn!(
                "Identity key mismatch for user {} -- rejecting upload",
                auth_user.user_id,
            );
            return Err(AppError::conflict(
                "Identity key changed; use key reset flow to rotate",
            ));
        }
        _ => {} // First upload or same key -- OK
    }

    let one_time_prekeys: Vec<(i32, Vec<u8>)> = body
        .one_time_prekeys
        .iter()
        .map(|otk| {
            let pk = BASE64
                .decode(&otk.public_key)
                .map_err(|_| AppError::bad_request("Invalid base64 for one_time_prekey"))?;
            if pk.len() != 32 {
                return Err(AppError::bad_request(
                    "one_time_prekey must be exactly 32 bytes (X25519)",
                ));
            }
            Ok((otk.key_id, pk))
        })
        .collect::<Result<Vec<_>, AppError>>()?;

    // Wrap all key stores in a transaction to prevent partial uploads.
    let mut tx = state.pool.begin().await.map_err(|e| {
        tracing::error!("Failed to begin key upload transaction: {e:?}");
        AppError::internal("Database error")
    })?;

    // Bind the identity key fingerprint on first upload.
    if stored_fingerprint.is_none() {
        db::keys::set_identity_key_fingerprint(&mut *tx, auth_user.user_id, &new_fingerprint)
            .await?;
    }

    db::keys::store_identity_key(
        &mut *tx,
        auth_user.user_id,
        device_id,
        &identity_key,
        Some(&signing_key_bytes),
        body.platform.as_deref(),
    )
    .await?;
    db::keys::store_signed_prekey(
        &mut tx,
        auth_user.user_id,
        device_id,
        body.signed_prekey_id,
        &signed_prekey,
        &signed_prekey_signature,
    )
    .await?;

    if !one_time_prekeys.is_empty() {
        db::keys::store_one_time_prekeys(&mut tx, auth_user.user_id, device_id, &one_time_prekeys)
            .await?;
    }

    tx.commit().await.map_err(|e| {
        tracing::error!("Failed to commit key upload transaction: {e:?}");
        AppError::internal("Database error")
    })?;

    tracing::info!(
        "PreKey bundle uploaded for user {} device {} ({} OTPs)",
        auth_user.user_id,
        device_id,
        one_time_prekeys.len()
    );

    Ok(StatusCode::CREATED)
}

/// Verify that the signed_prekey_signature was produced by the given Ed25519 signing key
/// over the signed_prekey bytes.
fn verify_signed_prekey_signature(
    signing_key_bytes: &[u8],
    signed_prekey_bytes: &[u8],
    signature_bytes: &[u8],
) -> Result<(), AppError> {
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};

    let key_array: [u8; 32] = signing_key_bytes
        .try_into()
        .map_err(|_| AppError::bad_request("signing_key must be exactly 32 bytes"))?;
    let verifying_key = VerifyingKey::from_bytes(&key_array)
        .map_err(|_| AppError::bad_request("Invalid Ed25519 signing key"))?;

    let sig_array: [u8; 64] = signature_bytes
        .try_into()
        .map_err(|_| AppError::bad_request("signed_prekey_signature must be exactly 64 bytes"))?;
    let signature = Signature::from_bytes(&sig_array);

    verifying_key
        .verify(signed_prekey_bytes, &signature)
        .map_err(|_| AppError::bad_request("Signed prekey signature verification failed"))?;

    Ok(())
}

/// GET /api/keys/bundle/:user_id -- Fetch a user's PreKey bundle.
///
/// Tries device 0 first (legacy), then falls back to any device that has a
/// bundle uploaded. This handles the case where clients generate random device
/// IDs (e.g. web clients that can't persist device ID across sessions).
pub async fn get_bundle(
    State(state): State<Arc<AppState>>,
    _auth_user: AuthUser,
    Path(user_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Try device 0 first (legacy single-device clients)
    let bundle = match db::keys::get_prekey_bundle(&state.pool, user_id, 0).await? {
        Some(b) => b,
        None => {
            // No device 0 — find the most recently registered device and use that
            let devices = db::keys::get_user_devices(&state.pool, user_id).await?;
            let mut found = None;
            for device in devices {
                if let Some(b) =
                    db::keys::get_prekey_bundle(&state.pool, user_id, device.device_id).await?
                {
                    found = Some(b);
                    break;
                }
            }
            found.ok_or_else(|| AppError::bad_request("No PreKey bundle found for this user"))?
        }
    };

    let signing_key = require_signing_key(&bundle, user_id)?;

    let response = PreKeyBundleResponse {
        identity_key: BASE64.encode(&bundle.identity_key),
        signing_key,
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

/// GET /api/keys/bundle/:user_id/:device_id -- Fetch a PreKey bundle for a specific device.
pub async fn get_device_bundle(
    State(state): State<Arc<AppState>>,
    _auth_user: AuthUser,
    Path((user_id, device_id)): Path<(Uuid, i32)>,
) -> Result<impl IntoResponse, AppError> {
    let bundle = db::keys::get_prekey_bundle(&state.pool, user_id, device_id)
        .await?
        .ok_or_else(|| {
            AppError::bad_request("No PreKey bundle found for this user/device combination")
        })?;

    let signing_key = require_signing_key(&bundle, user_id)?;

    let response = PreKeyBundleResponse {
        identity_key: BASE64.encode(&bundle.identity_key),
        signing_key,
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

/// GET /api/keys/devices/:user_id -- List all devices for a user, including
/// their platform and last_seen timestamp.
pub async fn get_devices(
    State(state): State<Arc<AppState>>,
    _auth_user: AuthUser,
    Path(user_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let rows = db::keys::get_user_devices(&state.pool, user_id).await?;
    let devices: Vec<DeviceInfo> = rows.into_iter().map(DeviceInfo::from).collect();
    Ok(Json(DeviceListResponse { user_id, devices }))
}

/// Response for a single device bundle within the all-bundles response.
#[derive(Debug, Serialize)]
pub struct DeviceBundleResponse {
    pub device_id: i32,
    pub identity_key: String,
    pub signing_key: String,
    pub signed_prekey: String,
    pub signed_prekey_signature: String,
    pub signed_prekey_id: i32,
    pub one_time_prekey: Option<OneTimePreKeyResponse>,
}

/// GET /api/keys/bundles/:user_id -- Fetch ALL device bundles for a user.
///
/// Returns bundles for every registered device in a single request,
/// enabling multi-device encryption without N+1 round trips.
pub async fn get_all_bundles(
    State(state): State<Arc<AppState>>,
    _auth_user: AuthUser,
    Path(user_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let devices = db::keys::get_user_devices(&state.pool, user_id).await?;
    let mut bundles = Vec::new();

    for device in devices {
        let device_id = device.device_id;
        if let Some(bundle) = db::keys::get_prekey_bundle(&state.pool, user_id, device_id).await? {
            let signing_key = match require_signing_key(&bundle, user_id) {
                Ok(sk) => sk,
                Err(_) => continue, // skip devices with legacy bundles missing signing key
            };
            bundles.push(DeviceBundleResponse {
                device_id,
                identity_key: BASE64.encode(&bundle.identity_key),
                signing_key,
                signed_prekey: BASE64.encode(&bundle.signed_prekey),
                signed_prekey_signature: BASE64.encode(&bundle.signed_prekey_signature),
                signed_prekey_id: bundle.signed_prekey_id,
                one_time_prekey: bundle.one_time_prekey.map(|otk| OneTimePreKeyResponse {
                    key_id: otk.key_id,
                    public_key: BASE64.encode(&otk.public_key),
                }),
            });
        }
    }

    Ok(Json(serde_json::json!({ "bundles": bundles })))
}

/// DELETE /api/keys/device/:device_id -- Revoke a specific device for the
/// authenticated user. Deletes all stored keys for that device and broadcasts
/// a `device_revoked` event to all of the user's connected sessions.
pub async fn revoke_device(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Path(device_id): Path<i32>,
) -> Result<impl IntoResponse, AppError> {
    use crate::ws::handler::ServerMessage;
    use axum::extract::ws::Message as WsMessage;

    let found = db::keys::revoke_device(&state.pool, auth_user.user_id, device_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?;

    if !found {
        return Err(AppError {
            status: axum::http::StatusCode::NOT_FOUND,
            message: "Device not found".to_string(),
        });
    }

    // Notify all of this user's active sessions so they can handle the revocation.
    let event = ServerMessage::DeviceRevoked { device_id };
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .send_to_user(&auth_user.user_id, WsMessage::Text(json.into()));
    }

    Ok(axum::http::StatusCode::NO_CONTENT)
}

/// Request body for `POST /api/keys/devices/revoke-others`.
#[derive(Debug, Deserialize)]
pub struct RevokeOthersRequest {
    pub current_device_id: i32,
}

/// POST /api/keys/devices/revoke-others -- Revoke every device belonging to
/// the authenticated user except `current_device_id`. Broadcasts a
/// `device_revoked` event for each revoked device so live sessions log out
/// immediately. Returns `{ "revoked": <count> }`.
pub async fn revoke_other_devices(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(body): Json<RevokeOthersRequest>,
) -> Result<impl IntoResponse, AppError> {
    use crate::ws::handler::ServerMessage;
    use axum::extract::ws::Message as WsMessage;

    // Self-lockout guard: refuse the request if the caller's current_device_id
    // is not actually registered for this user. Without this check a client
    // that passed a bogus ID (e.g. after a botched re-install) would silently
    // wipe every one of its own devices.
    let devices = db::keys::get_user_devices(&state.pool, auth_user.user_id).await?;
    if !devices
        .iter()
        .any(|d| d.device_id == body.current_device_id)
    {
        return Err(AppError::bad_request(
            "current_device_id not found among your registered devices",
        ));
    }

    // Perform the bulk delete in a single transaction and get back the list
    // of revoked device IDs for WS fan-out.
    let revoked_ids =
        db::keys::revoke_devices_except(&state.pool, auth_user.user_id, body.current_device_id)
            .await
            .map_err(|e| {
                tracing::error!("revoke_devices_except failed: {e:?}");
                AppError::internal("Database error")
            })?;

    for device_id in &revoked_ids {
        let event = ServerMessage::DeviceRevoked {
            device_id: *device_id,
        };
        if let Ok(json) = serde_json::to_string(&event) {
            state
                .hub
                .send_to_user(&auth_user.user_id, WsMessage::Text(json.into()));
        }
    }

    tracing::info!(
        "User {} revoked {} other devices (kept device {})",
        auth_user.user_id,
        revoked_ids.len(),
        body.current_device_id,
    );

    Ok(Json(serde_json::json!({ "revoked": revoked_ids.len() })))
}

/// Request body for key reset -- requires current password for re-authentication.
#[derive(Debug, Deserialize)]
pub struct ResetKeysRequest {
    pub password: String,
}

/// POST /api/keys/reset -- Clear the identity key fingerprint binding so the
/// user can upload a fresh key bundle. Requires password re-authentication
/// to prevent abuse.
pub async fn reset_keys(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(body): Json<ResetKeysRequest>,
) -> Result<impl IntoResponse, AppError> {
    use crate::auth::password;

    // Always require password -- key reset is the most security-critical
    // operation. A stolen JWT must not be sufficient to replace identity keys.
    if body.password.is_empty() {
        return Err(AppError::bad_request("Password is required for key reset"));
    }

    let user = db::users::find_by_id(&state.pool, auth_user.user_id)
        .await
        .map_err(|_| AppError::internal("Database error"))?
        .ok_or_else(|| AppError::bad_request("User not found"))?;

    let pw = body.password.clone();
    let hash = user.password_hash.clone();
    let valid = tokio::task::spawn_blocking(move || password::verify_password(&pw, &hash))
        .await
        .map_err(|_| AppError::internal("Password verification failed"))??;

    if !valid {
        return Err(AppError::unauthorized("Invalid password"));
    }

    // Clear the fingerprint so the next upload_bundle can bind a new one
    db::keys::clear_identity_key_fingerprint(&state.pool, auth_user.user_id).await?;

    tracing::info!(
        "Identity key fingerprint cleared for user {} (key reset)",
        auth_user.user_id,
    );

    // Notify all of this user's active sessions so they can detect the reset.
    use axum::extract::ws::Message as WsMessage;
    let event = serde_json::json!({
        "type": "identity_reset",
        "user_id": auth_user.user_id,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .send_to_user(&auth_user.user_id, WsMessage::Text(json.into()));
    }

    Ok(StatusCode::NO_CONTENT)
}

/// Query parameters for the OTP count endpoint.
#[derive(Debug, Deserialize)]
pub struct OtpCountQuery {
    #[serde(default)]
    pub device_id: i32,
}

/// GET /api/keys/otp-count -- return the number of unused one-time prekeys
/// for the authenticated user's device so the client can decide whether to
/// replenish.
pub async fn get_otp_count(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    axum::extract::Query(query): axum::extract::Query<OtpCountQuery>,
) -> Result<impl IntoResponse, AppError> {
    let count =
        db::keys::count_one_time_prekeys(&state.pool, auth_user.user_id, query.device_id).await?;
    Ok(Json(serde_json::json!({ "count": count })))
}
