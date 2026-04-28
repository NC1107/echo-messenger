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
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use uuid::Uuid;

use crate::auth::{jwt, middleware::AuthUser};
use crate::db;
use crate::error::AppError;

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

/// Read the file field, validate size and magic-byte content type.
async fn validate_and_read_file(
    field: axum::extract::multipart::Field<'_>,
) -> Result<(String, String, Vec<u8>), AppError> {
    let original_filename = field.file_name().unwrap_or("upload").to_string();
    let declared_mime = field.content_type().unwrap_or("").to_string();

    let data = field
        .bytes()
        .await
        .map_err(|e| AppError::bad_request(format!("Failed to read file data: {e}")))?
        .to_vec();

    let mime_type = validate_bytes(&data, &declared_mime)?;
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

    // Stat the file once so we can advertise Content-Length and serve byte
    // ranges. iOS AVFoundation refuses to play video URLs that don't
    // properly support `Range:` requests ("the server is not correctly
    // configured" — the symptom the user hit on their iPhone).
    let metadata = fs::metadata(&disk_path).await.map_err(|e| {
        tracing::error!("Failed to stat media file {}: {}", disk_path, e);
        AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media file not found on disk".to_string(),
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
                    .header(
                        CONTENT_RANGE,
                        format!("bytes {start}-{end}/{total_size}"),
                    )
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

    // No Range header — return the full body but advertise that we'd serve
    // a partial response on demand. AVFoundation uses the presence of
    // `Accept-Ranges: bytes` to decide whether to attempt streaming.
    let data = fs::read(&disk_path).await.map_err(|e| {
        tracing::error!("Failed to read media file {}: {}", disk_path, e);
        AppError {
            status: StatusCode::NOT_FOUND,
            message: "Media file not found on disk".to_string(),
        }
    })?;

    let response = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, &row.mime_type)
        .header(CONTENT_DISPOSITION, &disposition)
        .header(ACCEPT_RANGES, "bytes")
        .header(CONTENT_LENGTH, total_size)
        .body(Body::from(data))
        .map_err(|e| AppError::internal(format!("Failed to build response: {e}")))?;

    Ok(response)
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
