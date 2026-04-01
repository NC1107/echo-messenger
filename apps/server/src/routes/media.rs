//! Media upload and download endpoints.

use axum::body::Body;
use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::http::header::{CONTENT_DISPOSITION, CONTENT_TYPE};
use axum::response::{IntoResponse, Response};
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;

use super::AppState;

/// Maximum upload size: 10 MB.
const MAX_FILE_SIZE: usize = 10 * 1024 * 1024;

/// Allowed MIME types for upload.
const ALLOWED_MIME_TYPES: &[&str] = &[
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "video/mp4",
    "application/pdf",
];

/// Derive a file extension from a MIME type.
fn extension_for_mime(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "video/mp4" => "mp4",
        "application/pdf" => "pdf",
        _ => "bin",
    }
}

/// POST /api/media/upload
///
/// Accepts multipart form data with a `file` field.
/// Saves the file to `./uploads/{uuid}.{ext}` and creates a DB record.
pub async fn upload(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> Result<impl IntoResponse, AppError> {
    // Ensure uploads directory exists
    fs::create_dir_all("./uploads")
        .await
        .map_err(|e| AppError::internal(format!("Failed to create uploads directory: {e}")))?;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::bad_request(format!("Invalid multipart data: {e}")))?
    {
        let field_name = field.name().unwrap_or_default().to_string();
        if field_name != "file" {
            continue;
        }

        let original_filename = field.file_name().unwrap_or("upload").to_string();

        let mime_type = field
            .content_type()
            .unwrap_or("application/octet-stream")
            .to_string();

        if !ALLOWED_MIME_TYPES.contains(&mime_type.as_str()) {
            return Err(AppError::bad_request(format!(
                "File type '{mime_type}' is not allowed. Allowed types: {}",
                ALLOWED_MIME_TYPES.join(", ")
            )));
        }

        let data = field
            .bytes()
            .await
            .map_err(|e| AppError::bad_request(format!("Failed to read file data: {e}")))?;

        if data.len() > MAX_FILE_SIZE {
            return Err(AppError::bad_request(format!(
                "File too large. Maximum size is {} bytes",
                MAX_FILE_SIZE
            )));
        }

        let ext = extension_for_mime(&mime_type);
        let file_uuid = Uuid::new_v4();
        let disk_filename = format!("{file_uuid}.{ext}");
        let disk_path = format!("./uploads/{disk_filename}");

        fs::write(&disk_path, &data)
            .await
            .map_err(|e| AppError::internal(format!("Failed to save file: {e}")))?;

        let row = db::media::create_media(
            &state.pool,
            auth.user_id,
            &original_filename,
            &mime_type,
            data.len() as i64,
        )
        .await?;

        let body = json!({
            "id": row.id.to_string(),
            "url": format!("/api/media/{}", row.id),
        });

        return Ok((StatusCode::CREATED, axum::Json(body)));
    }

    Err(AppError::bad_request(
        "Missing 'file' field in multipart form data",
    ))
}

/// GET /api/media/:id
///
/// Returns the file with correct Content-Type and Content-Disposition headers.
pub async fn download(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AppError> {
    let row = db::media::get_media(&state.pool, id)
        .await?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media not found".to_string(),
        })?;

    // Authorization: only the uploader can download directly
    if row.uploader_id != auth.user_id {
        return Err(AppError {
            status: StatusCode::FORBIDDEN,
            message: "You do not have access to this media".to_string(),
        });
    }

    let ext = extension_for_mime(&row.mime_type);
    let disk_path = format!("./uploads/{id}.{ext}");

    let data = fs::read(&disk_path).await.map_err(|e| {
        tracing::error!("Failed to read media file {}: {}", disk_path, e);
        AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media file not found on disk".to_string(),
        }
    })?;

    // Sanitize filename: strip characters that could break Content-Disposition header
    let safe_filename: String = row
        .filename
        .chars()
        .filter(|c| *c != '"' && *c != '\\' && *c != '\r' && *c != '\n' && *c != '/' && *c != '\0')
        .collect();
    let safe_filename = if safe_filename.is_empty() {
        id.to_string()
    } else {
        safe_filename
    };

    let response = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, &row.mime_type)
        .header(
            CONTENT_DISPOSITION,
            format!("inline; filename=\"{}\"", safe_filename),
        )
        .body(Body::from(data))
        .map_err(|e| AppError::internal(format!("Failed to build response: {e}")))?;

    Ok(response)
}
