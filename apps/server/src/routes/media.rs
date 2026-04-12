//! Media upload and download endpoints.

use axum::Json;
use axum::body::Body;
use axum::extract::{Multipart, Path, Query, State};
use axum::http::StatusCode;
use axum::http::header::{CONTENT_DISPOSITION, CONTENT_TYPE};
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::fs;
use uuid::Uuid;

use crate::auth::{jwt, middleware::AuthUser};
use crate::db;
use crate::error::AppError;

use super::AppState;

/// Maximum upload size: 10 MB.
const MAX_FILE_SIZE: usize = 10 * 1024 * 1024;

/// Allowed MIME types for upload.
const ALLOWED_MIME_TYPES: &[&str] = &[
    // Images
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    // Video
    "video/mp4",
    // Audio
    "audio/mpeg",
    "audio/ogg",
    "audio/wav",
    // Documents
    "application/pdf",
    "text/plain",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    // Archives
    "application/zip",
    "application/x-7z-compressed",
    "application/x-tar",
    "application/gzip",
    // Generic binary
    "application/octet-stream",
];

/// Derive a file extension from a MIME type.
fn extension_for_mime(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "video/mp4" => "mp4",
        "audio/mpeg" => "mp3",
        "audio/ogg" => "ogg",
        "audio/wav" => "wav",
        "application/pdf" => "pdf",
        "text/plain" => "txt",
        "application/msword" => "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
        "application/vnd.ms-excel" => "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
        "application/zip" => "zip",
        "application/x-7z-compressed" => "7z",
        "application/x-tar" => "tar",
        "application/gzip" => "gz",
        _ => "bin",
    }
}

/// Read the file field, validate MIME type, size, and magic-byte content type.
async fn validate_and_read_file(
    field: axum::extract::multipart::Field<'_>,
) -> Result<(String, String, Vec<u8>), AppError> {
    let original_filename = field.file_name().unwrap_or("upload").to_string();

    let mut mime_type = field
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
        .map_err(|e| AppError::bad_request(format!("Failed to read file data: {e}")))?
        .to_vec();

    if data.len() > MAX_FILE_SIZE {
        return Err(AppError::bad_request(format!(
            "File too large. Maximum size is {} bytes",
            MAX_FILE_SIZE
        )));
    }

    // Validate actual file type via magic bytes -- don't trust client MIME header
    match infer::get(&data) {
        Some(inferred) => {
            let inferred_mime = inferred.mime_type();
            if !ALLOWED_MIME_TYPES.contains(&inferred_mime) {
                return Err(AppError::bad_request(format!(
                    "Detected file type '{inferred_mime}' is not allowed"
                )));
            }
            mime_type = inferred_mime.to_string();
        }
        None => {
            return Err(AppError::bad_request(
                "Could not detect file type from content. Upload a supported format.",
            ));
        }
    }

    Ok((original_filename, mime_type, data))
}

/// POST /api/media/upload
///
/// Accepts multipart form data with a `file` field and an optional
/// `conversation_id` field.  Saves the file to `./uploads/{uuid}.{ext}`
/// and creates a DB record.
pub async fn upload(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> Result<impl IntoResponse, AppError> {
    // Ensure uploads directory exists
    fs::create_dir_all("./uploads")
        .await
        .map_err(|e| AppError::internal(format!("Failed to create uploads directory: {e}")))?;

    let mut file_data: Option<(String, String, Vec<u8>)> = None;
    let mut conversation_id: Option<Uuid> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::bad_request(format!("Invalid multipart data: {e}")))?
    {
        let field_name = field.name().unwrap_or_default().to_string();

        if field_name == "conversation_id" {
            let text = field
                .text()
                .await
                .map_err(|e| AppError::bad_request(format!("Invalid conversation_id: {e}")))?;
            let cid = text
                .parse::<Uuid>()
                .map_err(|_| AppError::bad_request("conversation_id must be a valid UUID"))?;

            // Verify the uploader is a member of this conversation
            let is_member = db::groups::is_member(&state.pool, cid, auth.user_id)
                .await
                .map_err(|e| {
                    tracing::error!("DB error in upload_media/is_member: {e:?}");
                    AppError::internal("Database error")
                })?;
            if !is_member {
                return Err(AppError {
                    status: StatusCode::FORBIDDEN,
                    message: "Not a member of this conversation".to_string(),
                });
            }
            conversation_id = Some(cid);
            continue;
        }

        if field_name != "file" {
            continue;
        }

        file_data = Some(validate_and_read_file(field).await?);
    }

    let (original_filename, mime_type, data) = file_data
        .ok_or_else(|| AppError::bad_request("Missing 'file' field in multipart form data"))?;

    let ext = extension_for_mime(&mime_type);
    let file_uuid = Uuid::new_v4();
    let disk_filename = format!("{file_uuid}.{ext}");
    let disk_path = format!("./uploads/{disk_filename}");

    fs::write(&disk_path, &data)
        .await
        .map_err(|e| AppError::internal(format!("Failed to save file: {e}")))?;

    let row = db::media::create_media(
        &state.pool,
        file_uuid,
        auth.user_id,
        &original_filename,
        &mime_type,
        data.len() as i64,
        conversation_id,
    )
    .await?;

    let body = json!({
        "id": row.id.to_string(),
        "url": format!("/api/media/{}", row.id),
    });

    Ok((StatusCode::CREATED, axum::Json(body)))
}

// ---------------------------------------------------------------------------
// POST /api/media/ticket
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct MediaTicketResponse {
    pub ticket: String,
}

/// Issue a short-lived, single-use ticket for media downloads.
/// Prevents JWT leakage in query strings, browser history, and referrer
/// headers (same pattern as WebSocket tickets).
pub async fn request_media_ticket(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
) -> Result<impl IntoResponse, AppError> {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use rand::RngCore;

    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    let ticket = URL_SAFE_NO_PAD.encode(bytes);

    const TICKET_TTL: Duration = Duration::from_secs(300); // 5 minutes
    const MAX_TICKETS: usize = 100_000;

    // Clean up expired tickets to bound memory
    let now = Instant::now();
    state
        .media_tickets
        .retain(|_, (_, ts)| now.duration_since(*ts) < TICKET_TTL);

    if state.media_tickets.len() >= MAX_TICKETS {
        return Err(AppError::bad_request(
            "Too many pending media tickets, try again later",
        ));
    }

    state
        .media_tickets
        .insert(ticket.clone(), (auth_user.user_id, now));

    Ok(Json(MediaTicketResponse { ticket }))
}

/// Query param for media download -- accepts `?ticket=` (single-use media
/// ticket), legacy `?token=` (validated as media ticket, not JWT), or
/// `?jwt=` (for web clients where <img> tags cannot send auth headers).
#[derive(Debug, Deserialize)]
pub struct MediaDownloadQuery {
    pub ticket: Option<String>,
    pub token: Option<String>,
    pub jwt: Option<String>,
}

/// GET /api/media/:id
///
/// Returns the file with correct Content-Type and Content-Disposition headers.
/// Accepts auth via:
///   1. `Authorization: Bearer <JWT>` header
///   2. `?ticket=<media_ticket>` query param (single-use, consumed on use)
///   3. `?token=<media_ticket>` query param (legacy compat, same as ticket)
pub async fn download(
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    Query(query): Query<MediaDownloadQuery>,
    headers: axum::http::HeaderMap,
) -> Result<Response, AppError> {
    // 1. Try Authorization header (JWT)
    let user_id = if let Some(token_str) = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
    {
        let claims = jwt::validate_token(token_str, &state.jwt_secret)?;
        Uuid::parse_str(&claims.sub)
            .map_err(|_| AppError::unauthorized("Invalid user ID in token"))?
    }
    // 2. Try ?jwt= query param (for web clients where <img> tags cannot send headers)
    else if let Some(jwt_str) = &query.jwt {
        let claims = jwt::validate_token(jwt_str, &state.jwt_secret)?;
        Uuid::parse_str(&claims.sub)
            .map_err(|_| AppError::unauthorized("Invalid user ID in token"))?
    }
    // 3. Try ?ticket= or legacy ?token= as media ticket
    else if let Some(ticket_str) = query.ticket.or(query.token) {
        validate_media_ticket(&state, &ticket_str)?
    } else {
        return Err(AppError::unauthorized("Missing authentication"));
    };
    let row = db::media::get_media(&state.pool, id)
        .await?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media not found".to_string(),
        })?;

    // ACL: verify the requesting user can access this media
    let allowed = db::media::can_user_access_media(&state.pool, id, user_id)
        .await
        .map_err(|e| {
            tracing::error!("Media ACL check failed: {e}");
            AppError::internal("Database error")
        })?;

    if !allowed {
        // Return 404 (not 403) to avoid revealing whether the file exists.
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media not found".to_string(),
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

/// Validate a single-use media ticket. Removes the ticket from the store
/// on success (single-use). Returns the associated `user_id`.
fn validate_media_ticket(state: &AppState, ticket: &str) -> Result<Uuid, AppError> {
    const TICKET_TTL: Duration = Duration::from_secs(300);

    let (_, (user_id, created_at)) = state
        .media_tickets
        .remove(ticket)
        .ok_or_else(|| AppError::unauthorized("Invalid or expired media ticket"))?;

    if Instant::now().duration_since(created_at) >= TICKET_TTL {
        return Err(AppError::unauthorized("Invalid or expired media ticket"));
    }

    Ok(user_id)
}
