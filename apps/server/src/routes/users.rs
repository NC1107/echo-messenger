//! User profile endpoints: avatar upload and serving.

use axum::Json;
use axum::body::Body;
use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::http::header::CONTENT_TYPE;
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

#[derive(Serialize)]
pub struct UserProfile {
    pub user_id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub bio: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize)]
pub struct PrivacyPreferencesResponse {
    pub read_receipts_enabled: bool,
    pub allow_unencrypted_dm: bool,
}

#[derive(Deserialize)]
pub struct UpdatePrivacyPreferencesRequest {
    pub read_receipts_enabled: Option<bool>,
    pub allow_unencrypted_dm: Option<bool>,
}

/// GET /api/users/me/privacy
pub async fn get_my_privacy(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    let privacy = db::users::get_privacy_preferences(&state.pool, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_my_privacy: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("User not found"))?;

    Ok(Json(PrivacyPreferencesResponse {
        read_receipts_enabled: privacy.read_receipts_enabled,
        allow_unencrypted_dm: false,
    }))
}

/// PATCH /api/users/me/privacy
pub async fn update_my_privacy(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UpdatePrivacyPreferencesRequest>,
) -> Result<impl IntoResponse, AppError> {
    let current = db::users::get_privacy_preferences(&state.pool, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in update_my_privacy/get_current: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("User not found"))?;

    let updated = db::users::update_privacy_preferences(
        &state.pool,
        auth.user_id,
        payload
            .read_receipts_enabled
            .unwrap_or(current.read_receipts_enabled),
        false,
    )
    .await
    .map_err(|e| {
        tracing::error!("DB error in update_my_privacy: {e:?}");
        AppError::internal("Failed to update privacy settings")
    })?;

    Ok(Json(PrivacyPreferencesResponse {
        read_receipts_enabled: updated.read_receipts_enabled,
        allow_unencrypted_dm: false,
    }))
}

/// GET /api/users/:id/profile
///
/// Returns the public profile for a user.
pub async fn get_profile(
    _auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let profile = db::users::find_public_profile(&state.pool, user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in get_profile: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("User not found"))?;

    Ok(Json(UserProfile {
        user_id: profile.id,
        username: profile.username,
        display_name: profile.display_name,
        avatar_url: profile.avatar_url,
        bio: profile.bio,
        created_at: profile.created_at,
    }))
}

/// DELETE /api/users/me
///
/// Deletes the authenticated user's account. Revokes all refresh tokens first,
/// then deletes the user row (FK CASCADE handles contacts, messages, etc.).
pub async fn delete_account(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    // Revoke all refresh tokens
    db::tokens::revoke_all_user_tokens(&state.pool, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in delete_account/revoke_tokens: {e:?}");
            AppError::internal("Failed to revoke tokens")
        })?;

    // Disconnect from WebSocket hub if online
    state.hub.unregister(auth.user_id);

    // Delete user row (CASCADE handles related tables)
    let deleted = db::users::delete_user(&state.pool, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in delete_account/delete_user: {e:?}");
            AppError::internal("Failed to delete account")
        })?;

    if !deleted {
        return Err(AppError::internal("User not found"));
    }

    // Clean up avatar files from disk
    for ext in &["jpg", "png", "webp"] {
        let path = format!("./uploads/avatars/{}.{}", auth.user_id, ext);
        let _ = fs::remove_file(&path).await;
    }

    Ok(StatusCode::NO_CONTENT)
}

/// GET /api/users/online
///
/// Returns the list of currently connected user IDs, filtered to the
/// caller's contacts only (prevents platform-wide user enumeration).
pub async fn online_users(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    let contact_ids = db::contacts::list_contact_user_ids(&state.pool, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error in online_users/list_contacts: {e:?}");
            AppError::internal("Database error")
        })?;
    let all_online = state.hub.get_online_user_ids();
    let online_contacts: Vec<_> = all_online
        .into_iter()
        .filter(|id| contact_ids.contains(id))
        .collect();
    Ok(Json(
        serde_json::json!({ "online_user_ids": online_contacts }),
    ))
}

/// Maximum avatar size: 2 MB.
const MAX_AVATAR_SIZE: usize = 2 * 1024 * 1024;

/// Allowed avatar MIME types.
const ALLOWED_AVATAR_TYPES: &[&str] = &["image/jpeg", "image/png", "image/webp"];

/// Derive a file extension from a MIME type.
fn extension_for_mime(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        _ => "bin",
    }
}

/// Guess MIME type from file extension.
fn mime_for_extension(ext: &str) -> &str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        _ => "application/octet-stream",
    }
}

/// PUT /api/users/me/avatar
///
/// Accepts multipart form data with an `avatar` field.
/// Saves the file to `./uploads/avatars/{user_id}.{ext}` and updates the user record.
pub async fn upload_avatar(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> Result<impl IntoResponse, AppError> {
    fs::create_dir_all("./uploads/avatars")
        .await
        .map_err(|e| AppError::internal(format!("Failed to create avatars directory: {e}")))?;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::bad_request(format!("Invalid multipart data: {e}")))?
    {
        let field_name = field.name().unwrap_or_default().to_string();
        if field_name != "avatar" {
            continue;
        }

        let mime_type = field
            .content_type()
            .unwrap_or("application/octet-stream")
            .to_string();

        if !ALLOWED_AVATAR_TYPES.contains(&mime_type.as_str()) {
            return Err(AppError::bad_request(format!(
                "Avatar type '{mime_type}' is not allowed. Allowed types: {}",
                ALLOWED_AVATAR_TYPES.join(", ")
            )));
        }

        let data = field
            .bytes()
            .await
            .map_err(|e| AppError::bad_request(format!("Failed to read avatar data: {e}")))?;

        if data.len() > MAX_AVATAR_SIZE {
            return Err(AppError::bad_request(format!(
                "Avatar too large. Maximum size is {} bytes",
                MAX_AVATAR_SIZE
            )));
        }

        let ext = extension_for_mime(&mime_type);
        let disk_filename = format!("{}.{}", auth.user_id, ext);
        let disk_path = format!("./uploads/avatars/{disk_filename}");

        // Remove any old avatar files for this user (different extensions)
        for old_ext in &["jpg", "png", "webp"] {
            let old_path = format!("./uploads/avatars/{}.{}", auth.user_id, old_ext);
            let _ = fs::remove_file(&old_path).await;
        }

        fs::write(&disk_path, &data)
            .await
            .map_err(|e| AppError::internal(format!("Failed to save avatar: {e}")))?;

        let avatar_url = format!("/api/users/{}/avatar", auth.user_id);
        db::users::set_avatar_url(&state.pool, auth.user_id, &avatar_url).await?;

        return Ok((
            StatusCode::OK,
            axum::Json(json!({ "avatar_url": avatar_url })),
        ));
    }

    Err(AppError::bad_request(
        "Missing 'avatar' field in multipart form data",
    ))
}

/// GET /api/users/:id/avatar
///
/// Serves the avatar image with the correct Content-Type header.
/// Public endpoint — no auth required (avatars are profile pictures).
/// Returns 404 if no avatar is set.
pub async fn get_avatar(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<Uuid>,
) -> Result<Response, AppError> {
    // Verify user has an avatar_url set
    let avatar_url = db::users::get_avatar_url(&state.pool, user_id)
        .await?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this user".to_string(),
        })?;

    // Ensure the avatar_url actually points to this user
    let expected_prefix = format!("/api/users/{}/avatar", user_id);
    if avatar_url != expected_prefix {
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this user".to_string(),
        });
    }

    // Try to find the avatar file on disk
    for ext in &["jpg", "png", "webp"] {
        let disk_path = format!("./uploads/avatars/{}.{}", user_id, ext);
        if let Ok(data) = fs::read(&disk_path).await {
            let mime = mime_for_extension(ext);
            let response = Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, mime)
                .body(Body::from(data))
                .map_err(|e| AppError::internal(format!("Failed to build response: {e}")))?;
            return Ok(response);
        }
    }

    Err(AppError {
        status: StatusCode::NOT_FOUND,
        message: "Avatar file not found on disk".to_string(),
    })
}
