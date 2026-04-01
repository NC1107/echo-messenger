//! User profile endpoints: avatar upload and serving.

use axum::body::Body;
use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::http::header::CONTENT_TYPE;
use axum::response::{IntoResponse, Response};
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

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
