//! Media upload and download endpoints.

use axum::Json;
use axum::body::Body;
use axum::extract::{Multipart, Path, Query, State};
use axum::http::StatusCode;
use axum::http::header::{
    ACCEPT_RANGES, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, RANGE,
};
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::io::SeekFrom;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::fs;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::auth::{jwt, middleware::AuthUser};
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};

use super::AppState;

/// Maximum upload size: 100 MB. Sized for modern phone videos and reasonable
/// chat media; raise cautiously — both this constant and `DefaultBodyLimit`
/// in `routes/mod.rs` cap the multipart payload at this value.
pub const MAX_FILE_SIZE: usize = 100 * 1024 * 1024;

/// Allowed MIME types for upload.
const ALLOWED_MIME_TYPES: &[&str] = &[
    // Images
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "image/heic",
    "image/heif",
    // Video
    "video/mp4",
    "video/quicktime",
    "video/webm",
    "video/x-msvideo",
    // Audio
    "audio/mpeg",
    "audio/ogg",
    "audio/wav",
    "audio/mp4",
    "audio/aac",
    "audio/x-m4a",
    "audio/flac",
    "audio/x-flac",
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
];

/// Derive a file extension from a MIME type.
fn extension_for_mime(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/heic" | "image/heif" => "heic",
        "video/mp4" => "mp4",
        "video/quicktime" => "mov",
        "video/webm" => "webm",
        "video/x-msvideo" => "avi",
        "audio/mpeg" => "mp3",
        "audio/ogg" => "ogg",
        "audio/wav" => "wav",
        "audio/mp4" | "audio/x-m4a" => "m4a",
        "audio/aac" => "aac",
        "audio/flac" | "audio/x-flac" => "flac",
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

/// Validate file bytes against the allowed MIME types. The client-declared
/// MIME is untrusted; only the magic-byte signature determines the accepted
/// type. `text/plain` is special-cased because text files have no magic-byte
/// signature -- we accept it only when the client declared text/plain AND
/// the content is valid UTF-8.
///
/// Used by unit tests; production code uses `validate_head` + the streaming
/// byte counter in `stream_field_to_temp`.
#[cfg(test)]
fn validate_bytes(data: &[u8], declared_mime: &str) -> Result<String, AppError> {
    if data.len() > MAX_FILE_SIZE {
        return Err(AppError::bad_request(format!(
            "File too large. Maximum size is {MAX_FILE_SIZE} bytes"
        )));
    }

    match infer::get(data) {
        Some(inferred) => {
            let m = inferred.mime_type();
            // M4A audio files share the same MP4 container magic bytes as video/mp4.
            // When infer reports video/mp4 but the client declared an audio/mp4 type,
            // trust the declared audio MIME -- the container is valid regardless.
            let effective = if m == "video/mp4"
                && matches!(declared_mime, "audio/mp4" | "audio/x-m4a" | "audio/aac")
            {
                declared_mime
            } else {
                m
            };
            if !ALLOWED_MIME_TYPES.contains(&effective) {
                return Err(AppError::bad_request(format!(
                    "Detected file type '{m}' is not allowed"
                )));
            }
            Ok(effective.to_string())
        }
        None => {
            if declared_mime == "text/plain" && std::str::from_utf8(data).is_ok() {
                Ok("text/plain".to_string())
            } else {
                Err(AppError::bad_request(
                    "Could not detect file type from content. Upload a supported format.",
                ))
            }
        }
    }
}

/// Stream the multipart file field to a temp file, enforcing `MAX_FILE_SIZE`.
///
/// Returns `(original_filename, detected_mime, temp_path, file_size_bytes)`.
/// The temp file lives in `./uploads/` and must be renamed by the caller once
/// the final UUID-based filename is known.
///
/// # Streaming strategy
/// - First 512 bytes are accumulated in a small head buffer so `infer::get`
///   can detect the MIME type from magic bytes without buffering the whole
///   file.
/// - All chunks (including the head bytes) are written to a `tokio::fs::File`
///   as they arrive; peak RAM is O(chunk) rather than O(file).
/// - A running byte counter rejects the upload the moment it exceeds
///   `MAX_FILE_SIZE` — the connection is dropped before the full payload
///   lands on disk.
async fn stream_field_to_temp(
    mut field: axum::extract::multipart::Field<'_>,
) -> Result<(String, String, String, i64), AppError> {
    let original_filename = field.file_name().unwrap_or("upload").to_string();
    let declared_mime = field.content_type().unwrap_or("").to_string();

    // Write to a hidden temp file; renamed to the final path after validation.
    let temp_name = format!("./uploads/.tmp-{}", Uuid::new_v4());
    let mut tmp_file = fs::File::create(&temp_name)
        .await
        .map_err(|e| AppError::internal(format!("Failed to create temp upload file: {e}")))?;

    // First 512 bytes collected for MIME sniffing; infer only needs ~261.
    const SNIFF_LEN: usize = 512;
    let mut head: Vec<u8> = Vec::with_capacity(SNIFF_LEN);
    let mut total_bytes: usize = 0;

    loop {
        let chunk = field
            .chunk()
            .await
            .map_err(|e| AppError::bad_request(format!("Failed to read upload chunk: {e}")))?;

        let Some(bytes) = chunk else { break };
        if bytes.is_empty() {
            continue;
        }

        total_bytes += bytes.len();
        if total_bytes > MAX_FILE_SIZE {
            // Clean up the partial temp file before returning.
            drop(tmp_file);
            let _ = fs::remove_file(&temp_name).await;
            return Err(AppError::bad_request(format!(
                "File too large. Maximum size is {MAX_FILE_SIZE} bytes"
            )));
        }

        // Fill the head buffer up to SNIFF_LEN from the first chunk(s).
        if head.len() < SNIFF_LEN {
            let need = SNIFF_LEN - head.len();
            head.extend_from_slice(&bytes[..bytes.len().min(need)]);
        }

        tmp_file.write_all(&bytes).await.map_err(|e| {
            AppError::internal(format!("Failed to write upload chunk to disk: {e}"))
        })?;
    }

    tmp_file
        .flush()
        .await
        .map_err(|e| AppError::internal(format!("Failed to flush upload file: {e}")))?;
    drop(tmp_file);

    // MIME detection uses the head bytes only; no full-file buffering needed.
    let mime_type = validate_head(&head, &declared_mime).inspect_err(|_| {
        // Best-effort cleanup on MIME rejection; ignore removal errors.
        let temp = temp_name.clone();
        tokio::spawn(async move {
            let _ = fs::remove_file(temp).await;
        });
    })?;

    Ok((original_filename, mime_type, temp_name, total_bytes as i64))
}

/// Validate the magic bytes from the head buffer against the allowed MIME
/// types.  Mirrors `validate_bytes` but accepts a head slice rather than
/// requiring the whole file in RAM.
fn validate_head(head: &[u8], declared_mime: &str) -> Result<String, AppError> {
    match infer::get(head) {
        Some(inferred) => {
            let m = inferred.mime_type();
            // M4A audio files share the same MP4 container magic bytes as video/mp4.
            let effective = if m == "video/mp4"
                && matches!(declared_mime, "audio/mp4" | "audio/x-m4a" | "audio/aac")
            {
                declared_mime
            } else {
                m
            };
            if !ALLOWED_MIME_TYPES.contains(&effective) {
                return Err(AppError::bad_request(format!(
                    "Detected file type '{m}' is not allowed"
                )));
            }
            Ok(effective.to_string())
        }
        None => {
            if declared_mime == "text/plain" && std::str::from_utf8(head).is_ok() {
                Ok("text/plain".to_string())
            } else {
                Err(AppError::bad_request(
                    "Could not detect file type from content. Upload a supported format.",
                ))
            }
        }
    }
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

    // (original_filename, mime_type, temp_path, file_size)
    let mut file_data: Option<(String, String, String, i64)> = None;
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
                .db_ctx("upload_media/is_member")?;
            if !is_member {
                return Err(AppError {
                    status: StatusCode::FORBIDDEN,
                    message: "Not a member of this conversation".to_string(),
                    code: ErrorCode::Forbidden,
                    body: None,
                });
            }
            conversation_id = Some(cid);
            continue;
        }

        if field_name != "file" {
            continue;
        }

        file_data = Some(stream_field_to_temp(field).await?);
    }

    let (original_filename, mime_type, temp_path, file_size) = file_data
        .ok_or_else(|| AppError::bad_request("Missing 'file' field in multipart form data"))?;

    let ext = extension_for_mime(&mime_type);
    let file_uuid = Uuid::new_v4();
    let disk_filename = format!("{file_uuid}.{ext}");
    let disk_path = format!("./uploads/{disk_filename}");

    // Atomically rename temp -> final path; no extra copy needed.
    fs::rename(&temp_path, &disk_path).await.map_err(|e| {
        let tmp = temp_path.clone();
        tokio::spawn(async move {
            let _ = fs::remove_file(tmp).await;
        });
        AppError::internal(format!("Failed to save file: {e}"))
    })?;

    let row = db::media::create_media(
        &state.pool,
        file_uuid,
        auth.user_id,
        &original_filename,
        &mime_type,
        file_size,
        conversation_id,
    )
    .await?;

    // Generate a first-frame thumbnail for video uploads (#561). Best-effort:
    // we still return success even if ffmpeg is missing or fails — the client
    // falls back to a black tile when /thumb returns 404.
    let mut thumb_url: Option<String> = None;
    if mime_type.starts_with("video/") {
        let thumb_path = format!("./uploads/{file_uuid}.thumb.jpg");
        match generate_video_thumbnail(&disk_path, &thumb_path).await {
            Ok(()) => {
                thumb_url = Some(format!("/api/media/{}/thumb", row.id));
            }
            Err(e) => tracing::warn!(
                media_id = %row.id,
                "video thumbnail generation skipped: {e}"
            ),
        }
    }

    let mut body = json!({
        "id": row.id.to_string(),
        "url": format!("/api/media/{}", row.id),
    });
    if let Some(url) = thumb_url {
        body["thumb_url"] = json!(url);
    }

    Ok((StatusCode::CREATED, axum::Json(body)))
}

/// Run ffmpeg to extract the first frame of a video as a JPEG thumbnail.
/// Returns `Err` if ffmpeg isn't installed or exits non-zero — the caller
/// logs a warning and continues without a thumbnail (#561).
async fn generate_video_thumbnail(input: &str, output: &str) -> Result<(), String> {
    let result = tokio::process::Command::new("ffmpeg")
        .args([
            "-y",
            "-i",
            input,
            "-vf",
            "select=eq(n\\,0)",
            "-vframes",
            "1",
            "-q:v",
            "3",
            output,
        ])
        .output()
        .await
        .map_err(|e| format!("ffmpeg spawn failed: {e}"))?;
    if !result.status.success() {
        return Err(format!(
            "ffmpeg exit {}: {}",
            result.status,
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    Ok(())
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
    let ticket = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());

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

/// Query param for media download -- accepts `?ticket=` (reusable media
/// ticket, valid for 5 minutes) or legacy `?token=` (alias for ticket).
#[derive(Debug, Deserialize)]
pub struct MediaDownloadQuery {
    pub ticket: Option<String>,
    pub token: Option<String>,
}

/// GET /api/media/:id
///
/// Returns the file with correct Content-Type and Content-Disposition headers.
/// Accepts auth via:
///   1. `Authorization: Bearer <JWT>` header (native apps)
///   2. `?ticket=<media_ticket>` query param (web -- reusable within 5-min TTL)
///   3. `?token=<media_ticket>` query param (legacy alias for ticket)
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
    // 2. Try ?ticket= or legacy ?token= as media ticket
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
            code: ErrorCode::NotFound,
            body: None,
        })?;

    // ACL: verify the requesting user can access this media
    let allowed = db::media::can_user_access_media(&state.pool, id, user_id)
        .await
        .db_ctx("download/acl_check")?;

    if !allowed {
        // Return 404 (not 403) to avoid revealing whether the file exists.
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media not found".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        });
    }

    let ext = extension_for_mime(&row.mime_type);
    let disk_path = format!("./uploads/{id}.{ext}");

    // Stat the file once so we can advertise Content-Length and serve byte
    // ranges. iOS AVFoundation refuses to play video URLs that don't
    // properly support `Range:` requests ("the server is not correctly
    // configured" — the symptom the user hit on their iPhone).
    let metadata = fs::metadata(&disk_path).await.map_err(|e| {
        tracing::error!("Failed to stat media file {}: {}", disk_path, e);
        AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media file not found on disk".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        }
    })?;
    let total_size = metadata.len();

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
    let disposition = format!("inline; filename=\"{}\"", safe_filename);

    // Honor a Range request if present. We support a single open or closed
    // range; the multi-range form is rare in practice and AVFoundation
    // doesn't issue it.
    if let Some(range_header) = headers.get(RANGE).and_then(|v| v.to_str().ok()) {
        match parse_byte_range(range_header, total_size) {
            Ok((start, end)) => {
                let slice_len = end - start + 1;
                let mut file = fs::File::open(&disk_path).await.map_err(|e| {
                    tracing::error!("Failed to open media file for range: {e}");
                    AppError::internal("Failed to read media")
                })?;
                file.seek(SeekFrom::Start(start)).await.map_err(|e| {
                    tracing::error!("Failed to seek media file: {e}");
                    AppError::internal("Failed to read media")
                })?;
                let mut buf = vec![0u8; slice_len as usize];
                file.read_exact(&mut buf).await.map_err(|e| {
                    tracing::error!("Failed to read media slice: {e}");
                    AppError::internal("Failed to read media")
                })?;

                return Response::builder()
                    .status(StatusCode::PARTIAL_CONTENT)
                    .header(CONTENT_TYPE, &row.mime_type)
                    .header(CONTENT_DISPOSITION, &disposition)
                    .header(ACCEPT_RANGES, "bytes")
                    .header(CONTENT_LENGTH, slice_len)
                    .header(CONTENT_RANGE, format!("bytes {start}-{end}/{total_size}"))
                    .body(Body::from(buf))
                    .map_err(|e| AppError::internal(format!("Failed to build response: {e}")));
            }
            Err(_) => {
                // Unsatisfiable range — RFC 7233 says respond with 416.
                return Response::builder()
                    .status(StatusCode::RANGE_NOT_SATISFIABLE)
                    .header(CONTENT_RANGE, format!("bytes */{total_size}"))
                    .body(Body::empty())
                    .map_err(|e| AppError::internal(format!("Failed to build response: {e}")));
            }
        }
    }

    // No Range header — stream the full file without buffering it into RAM.
    // `ReaderStream` wraps the `tokio::fs::File` and yields chunks as they
    // are read from disk; peak RAM is O(chunk) regardless of file size.
    let file = fs::File::open(&disk_path).await.map_err(|e| {
        tracing::error!("Failed to open media file {}: {}", disk_path, e);
        AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media file not found on disk".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        }
    })?;

    let stream = ReaderStream::new(file);
    let response = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, &row.mime_type)
        .header(CONTENT_DISPOSITION, &disposition)
        .header(ACCEPT_RANGES, "bytes")
        .header(CONTENT_LENGTH, total_size)
        .body(Body::from_stream(stream))
        .map_err(|e| AppError::internal(format!("Failed to build response: {e}")))?;

    Ok(response)
}

/// GET /api/media/:id/thumb
///
/// Serve the JPEG first-frame thumbnail generated at upload time for
/// `video/*` media (#561). Same auth gate as `download()`. Returns 404 when
/// no thumbnail exists (non-video, or ffmpeg unavailable at upload time).
pub async fn download_thumb(
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    Query(query): Query<MediaDownloadQuery>,
    headers: axum::http::HeaderMap,
) -> Result<Response, AppError> {
    let user_id = if let Some(token_str) = headers
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
    {
        let claims = jwt::validate_token(token_str, &state.jwt_secret)?;
        Uuid::parse_str(&claims.sub)
            .map_err(|_| AppError::unauthorized("Invalid user ID in token"))?
    } else if let Some(ticket_str) = query.ticket.or(query.token) {
        validate_media_ticket(&state, &ticket_str)?
    } else {
        return Err(AppError::unauthorized("Missing authentication"));
    };

    // Fetch the media row first so we can derive the disk path from
    // DB-validated state — this also acts as a CodeQL sanitizer for the
    // path-traversal check on `id` (matching `download()`'s flow).
    let row = db::media::get_media(&state.pool, id)
        .await?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media not found".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        })?;

    let allowed = db::media::can_user_access_media(&state.pool, id, user_id)
        .await
        .db_ctx("thumbnail/acl_check")?;
    if !allowed {
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media not found".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        });
    }

    // Only video uploads have thumbnails; serve a quick 404 otherwise so
    // we don't read random `*.thumb.jpg` files that may have been planted.
    if !row.mime_type.starts_with("video/") {
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "Thumbnail not available".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        });
    }

    let thumb_path = format!("./uploads/{}.thumb.jpg", row.id);
    let data = fs::read(&thumb_path).await.map_err(|_| AppError {
        status: StatusCode::NOT_FOUND,
        message: "Thumbnail not available".to_string(),
        code: ErrorCode::NotFound,
        body: None,
    })?;

    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "image/jpeg")
        .header(CONTENT_LENGTH, data.len() as u64)
        .body(Body::from(data))
        .map_err(|e| AppError::internal(format!("Failed to build response: {e}")))
}

/// Parse an HTTP `Range: bytes=<start>-<end>` header against a known total
/// size. Returns the inclusive `(start, end)` byte offsets.
///
/// Supports:
///   - `bytes=0-499` → first 500 bytes
///   - `bytes=500-` → from 500 to EOF
///   - `bytes=-500` → last 500 bytes
///
/// Returns `Err(())` for malformed input or ranges past EOF.
fn parse_byte_range(header: &str, total_size: u64) -> Result<(u64, u64), ()> {
    let spec = header.strip_prefix("bytes=").ok_or(())?;
    // Reject multi-range requests (rare in practice; AVFoundation doesn't
    // issue them).
    if spec.contains(',') {
        return Err(());
    }
    let (s, e) = spec.split_once('-').ok_or(())?;
    if total_size == 0 {
        return Err(());
    }
    let last = total_size - 1;

    let (start, end) = if s.is_empty() {
        // Suffix range: bytes=-N — last N bytes.
        let n: u64 = e.parse().map_err(|_| ())?;
        if n == 0 {
            return Err(());
        }
        let n = n.min(total_size);
        (total_size - n, last)
    } else {
        let s: u64 = s.parse().map_err(|_| ())?;
        if e.is_empty() {
            (s, last)
        } else {
            let e: u64 = e.parse().map_err(|_| ())?;
            (s, e.min(last))
        }
    };

    if start > last || end < start {
        return Err(());
    }
    Ok((start, end))
}

/// Validate a media ticket.  Tickets are reusable within their 5-minute TTL
/// so that web `<img>` tags can load multiple images with the same ticket.
/// Expired tickets are rejected and removed.
fn validate_media_ticket(state: &AppState, ticket: &str) -> Result<Uuid, AppError> {
    const TICKET_TTL: Duration = Duration::from_secs(300);

    let entry = state
        .media_tickets
        .get(ticket)
        .ok_or_else(|| AppError::unauthorized("Invalid or expired media ticket"))?;

    let (user_id, created_at) = entry.value();
    if Instant::now().duration_since(*created_at) >= TICKET_TTL {
        drop(entry); // release read lock before mutation
        state.media_tickets.remove(ticket);
        return Err(AppError::unauthorized("Invalid or expired media ticket"));
    }

    Ok(*user_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Minimal valid PDF header -- enough for `infer::get` to detect.
    const PDF_BYTES: &[u8] =
        b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n1 0 obj\n<<>>\nendobj\ntrailer<<>>\n%%EOF";

    // Minimal ELF header (magic 7F 45 4C 46).
    const ELF_BYTES: &[u8] = b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00";

    #[test]
    fn validate_bytes_accepts_pdf() {
        let mime = validate_bytes(PDF_BYTES, "application/pdf").expect("PDF should validate");
        assert_eq!(mime, "application/pdf");
    }

    #[test]
    fn validate_bytes_ignores_declared_mime_for_known_signatures() {
        // Client lies about the type; magic bytes win.
        let mime = validate_bytes(PDF_BYTES, "application/octet-stream")
            .expect("PDF should validate regardless of declared MIME");
        assert_eq!(mime, "application/pdf");
    }

    #[test]
    fn validate_bytes_rejects_elf_executable() {
        // Either infer detects it as a disallowed executable type, or it
        // returns None and falls through to the "Could not detect" branch.
        // Both paths must reject, regardless of the declared MIME.
        let err = validate_bytes(ELF_BYTES, "application/octet-stream")
            .expect_err("ELF should be rejected");
        assert!(
            err.message.contains("is not allowed")
                || err.message.contains("Could not detect file type"),
            "unexpected error message: {}",
            err.message
        );
    }

    #[test]
    fn validate_bytes_accepts_utf8_text_with_text_plain_declared() {
        let data = "hello world\nthis is plain text\n".as_bytes();
        let mime = validate_bytes(data, "text/plain").expect("UTF-8 text should validate");
        assert_eq!(mime, "text/plain");
    }

    #[test]
    fn validate_bytes_rejects_text_without_text_plain_declaration() {
        let data = "hello world\n".as_bytes();
        let err = validate_bytes(data, "application/octet-stream")
            .expect_err("text without declaration should be rejected");
        assert!(err.message.contains("Could not detect file type"));
    }

    #[test]
    fn validate_bytes_rejects_invalid_utf8_declared_as_text() {
        // Invalid UTF-8 byte sequence that infer does not recognize.
        let data: &[u8] = &[0xC3, 0x28, 0xA1, 0xB2];
        let err = validate_bytes(data, "text/plain")
            .expect_err("invalid UTF-8 claiming text/plain should be rejected");
        assert!(err.message.contains("Could not detect file type"));
    }

    #[test]
    fn validate_bytes_rejects_oversize_file() {
        let data = vec![0u8; MAX_FILE_SIZE + 1];
        let err =
            validate_bytes(&data, "application/pdf").expect_err("oversize file should be rejected");
        assert!(err.message.contains("too large"));
    }

    #[test]
    fn octet_stream_is_not_in_allowed_list() {
        assert!(!ALLOWED_MIME_TYPES.contains(&"application/octet-stream"));
    }

    #[test]
    fn parse_byte_range_first_n() {
        assert_eq!(parse_byte_range("bytes=0-499", 1000), Ok((0, 499)));
    }

    #[test]
    fn parse_byte_range_open_ended() {
        assert_eq!(parse_byte_range("bytes=500-", 1000), Ok((500, 999)));
    }

    #[test]
    fn parse_byte_range_suffix() {
        assert_eq!(parse_byte_range("bytes=-200", 1000), Ok((800, 999)));
    }

    #[test]
    fn parse_byte_range_suffix_clamped_to_total() {
        assert_eq!(parse_byte_range("bytes=-2000", 1000), Ok((0, 999)));
    }

    #[test]
    fn parse_byte_range_end_clamped_to_last() {
        assert_eq!(parse_byte_range("bytes=0-9999", 1000), Ok((0, 999)));
    }

    #[test]
    fn parse_byte_range_rejects_multi_range() {
        assert!(parse_byte_range("bytes=0-100,200-300", 1000).is_err());
    }

    #[test]
    fn parse_byte_range_rejects_start_past_eof() {
        assert!(parse_byte_range("bytes=2000-3000", 1000).is_err());
    }

    #[test]
    fn parse_byte_range_rejects_zero_total() {
        assert!(parse_byte_range("bytes=0-100", 0).is_err());
    }

    #[test]
    fn parse_byte_range_rejects_zero_suffix() {
        assert!(parse_byte_range("bytes=-0", 1000).is_err());
    }

    #[test]
    fn parse_byte_range_rejects_missing_prefix() {
        assert!(parse_byte_range("0-100", 1000).is_err());
    }
}
