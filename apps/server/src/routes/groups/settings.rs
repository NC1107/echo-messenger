//! Group settings endpoints: update metadata and manage the group avatar.

use axum::Json;
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
use crate::error::{AppError, DbErrCtx, ErrorCode};
use crate::types::Role;

use super::super::AppState;
use super::types::UpdateGroupRequest;

/// Maximum group avatar size: 2 MB.
pub const MAX_GROUP_AVATAR_SIZE: usize = 2 * 1024 * 1024;

/// Allowed group avatar MIME types (validated via magic bytes, not client-supplied Content-Type).
const ALLOWED_GROUP_AVATAR_TYPES: &[&str] = &["image/jpeg", "image/png", "image/webp", "image/gif"];

fn avatar_extension_for_mime(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        _ => "bin",
    }
}

fn avatar_mime_for_extension(ext: &str) -> &str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "gif" => "image/gif",
        _ => "application/octet-stream",
    }
}

/// PUT /api/groups/:id -- Update group metadata (owner/admin only).
pub async fn update_group(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    Json(body): Json<UpdateGroupRequest>,
) -> Result<impl IntoResponse, AppError> {
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("update_group/get_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::forbidden(
            "Only the group owner or admin can update the group",
        ));
    }

    if let Some(title) = &body.title {
        let trimmed = title.trim();
        if trimmed.is_empty() {
            return Err(AppError::bad_request("Title cannot be empty"));
        }
        db::groups::update_group_title(&state.pool, group_id, trimmed)
            .await
            .db_ctx("update_group/title")?;
    }

    if let Some(ref desc) = body.description {
        db::groups::update_group_description(&state.pool, group_id, desc)
            .await
            .db_ctx("update_group/description")?;
    }

    Ok(Json(serde_json::json!({ "status": "updated" })))
}

/// PUT /api/groups/:id/avatar -- Upload a group avatar (owner/admin only).
///
/// Accepts multipart form data with an `avatar` field. Saves to
/// `./uploads/avatars/group_{id}.{ext}` and sets `icon_url` on the
/// conversation row.
pub async fn upload_group_avatar(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    mut multipart: Multipart,
) -> Result<impl IntoResponse, AppError> {
    // Verify caller is owner or admin
    let caller_role = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("upload_group_avatar/get_role")?
        .ok_or_else(|| AppError::with_code(ErrorCode::NotMember, "Not a member of this group"))?;

    let caller_role_enum = Role::from_str_opt(&caller_role).unwrap_or(Role::Member);
    if !caller_role_enum.is_admin_or_above() {
        return Err(AppError::forbidden(
            "Only the group owner or admin can change the avatar",
        ));
    }

    fs::create_dir_all("./uploads/avatars")
        .await
        .map_err(|e| AppError::internal(format!("Failed to create avatars directory: {e}")))?;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::bad_request(format!("Invalid multipart data: {e}")))?
    {
        // Accept "avatar" (historical) or "file" (matches /api/media/upload).
        let field_name = field.name().unwrap_or_default().to_string();
        if field_name != "avatar" && field_name != "file" {
            continue;
        }

        let data =
            super::super::users::read_avatar_field_capped(field, MAX_GROUP_AVATAR_SIZE).await?;

        // Validate via magic bytes, not client-declared Content-Type
        let mime_type = match infer::get(&data) {
            Some(inferred) => inferred.mime_type().to_string(),
            None => {
                return Err(AppError::with_code(
                    ErrorCode::UnsupportedMediaType,
                    "Could not determine avatar file type from content",
                ));
            }
        };

        if !ALLOWED_GROUP_AVATAR_TYPES.contains(&mime_type.as_str()) {
            return Err(AppError::with_code(
                ErrorCode::UnsupportedMediaType,
                format!(
                    "Avatar type '{mime_type}' is not allowed. \
                     Allowed: {}",
                    ALLOWED_GROUP_AVATAR_TYPES.join(", ")
                ),
            ));
        }

        let ext = avatar_extension_for_mime(&mime_type);
        let disk_filename = format!("group_{group_id}.{ext}");
        let disk_path = format!("./uploads/avatars/{disk_filename}");

        // Remove old avatar files for this group (different extensions)
        for old_ext in &["jpg", "png", "webp", "gif"] {
            let old = format!("./uploads/avatars/group_{group_id}.{old_ext}");
            let _ = fs::remove_file(&old).await;
        }

        fs::write(&disk_path, &data)
            .await
            .map_err(|e| AppError::internal(format!("Failed to save avatar: {e}")))?;

        let icon_url = format!("/api/groups/{group_id}/avatar");
        db::groups::update_group_icon_url(&state.pool, group_id, &icon_url)
            .await
            .db_ctx("upload_group_avatar/set_icon")?;

        return Ok((StatusCode::OK, Json(json!({ "avatar_url": icon_url }))));
    }

    Err(AppError::bad_request(
        "Missing avatar in multipart form data (expected field name 'avatar' or 'file')",
    ))
}

/// GET /api/groups/:id/avatar -- Serve the group avatar image.
/// Public endpoint — no auth required.
pub async fn get_group_avatar(
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<Response, AppError> {
    let icon_url = db::groups::get_group_icon_url(&state.pool, group_id)
        .await
        .db_ctx("get_group_avatar/icon_url")?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this group".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        })?;

    let expected = format!("/api/groups/{group_id}/avatar");
    if icon_url != expected {
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this group".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        });
    }

    for ext in &["jpg", "png", "webp", "gif"] {
        let disk_path = format!("./uploads/avatars/group_{group_id}.{ext}");
        if let Ok(data) = fs::read(&disk_path).await {
            let mime = avatar_mime_for_extension(ext);
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
        code: ErrorCode::NotFound,
        body: None,
    })
}
