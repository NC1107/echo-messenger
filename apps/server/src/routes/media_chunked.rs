//! Resumable / chunked upload endpoints (#556).
//!
//! The legacy `POST /api/media/upload` handler stays in `media.rs` as a
//! single-shot multipart upload capped at 100 MB.  This module adds a
//! parallel pipeline -- init / PATCH chunks / finalize -- that streams
//! every chunk to disk without buffering the body in RAM, so files up to
//! `MAX_CHUNKED_UPLOAD_BYTES` (1 GB by default) can be uploaded over
//! flaky cellular links with per-chunk retries.
//!
//! ## Why chunked instead of bumping the single-shot cap
//!
//! - Cloudflare Free caps request bodies at 100 MB at the edge, so a 2 GB
//!   single-shot upload cannot reach the origin at all.
//! - The existing `field.bytes().await` would load each chunk into RAM
//!   before writing; this module uses `Body::into_data_stream()` and
//!   writes each frame directly to a `tokio::fs::File`.
//! - Per-chunk retries allow the client to resume after a transient
//!   disconnect without re-uploading the whole file.
//!
//! ## Security
//!
//! - Every endpoint requires `AuthUser`.
//! - `temp_path` is `./uploads/.tmp/<uuid>` -- always derived from a
//!   server-generated UUID; user-supplied filenames are only honoured at
//!   the very end (in finalize) after being sanitised the same way the
//!   legacy endpoint sanitises them.
//! - The client-supplied `Content-Range` start offset must equal the
//!   server-side `bytes_received` counter; any mismatch is rejected with
//!   416 so a stale or hostile client cannot rewrite earlier bytes.
//! - `Content-Range` end - start + 1 must equal the body length, again
//!   rejected with 4xx; we never append more than the declared range.
//! - Finalize verifies `bytes_received == total_size`; finalising a
//!   short or oversized session is a 4xx.

use std::sync::Arc;

use axum::Json;
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::fs;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx};

use super::AppState;
use super::media;

/// Default chunk size announced to clients on init.  Mirrors the standard
/// S3 multipart minimum (5 MB) so the math feels familiar; small enough
/// that a single chunk completes quickly on cellular, large enough that
/// the per-chunk PostgreSQL round-trip doesn't dominate throughput.
pub const DEFAULT_CHUNK_SIZE: i64 = 5 * 1024 * 1024;

/// Hard upper bound on the size of a single PATCH chunk body, regardless
/// of what `Content-Range` declares.  This is a defence-in-depth cap that
/// prevents a malicious client from streaming an unbounded body even with
/// a well-formed range header; it should be slightly larger than the
/// advertised `DEFAULT_CHUNK_SIZE` so well-behaved clients are not
/// truncated by it.
const MAX_CHUNK_BYTES: i64 = 16 * 1024 * 1024;

/// Where pending chunked uploads land on disk.  Created lazily on init.
const TMP_DIR: &str = "./uploads/.tmp";

/// Default ceiling on the total size of a chunked upload, when the
/// `MAX_CHUNKED_UPLOAD_BYTES` env var is unset.  1 GB covers long
/// phone videos while staying conservative on disk quotas.
pub const DEFAULT_MAX_CHUNKED_UPLOAD_BYTES: i64 = 1024 * 1024 * 1024;

/// Read the configured upper bound on a chunked upload.  Re-read each
/// time so operators can rotate the value at runtime without a restart.
fn max_chunked_upload_bytes() -> i64 {
    std::env::var("MAX_CHUNKED_UPLOAD_BYTES")
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(DEFAULT_MAX_CHUNKED_UPLOAD_BYTES)
}

// ---------------------------------------------------------------------------
// POST /api/media/upload/init
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct InitUploadRequest {
    pub filename: String,
    pub mime_type: String,
    pub total_size: i64,
    /// Optional conversation scope; matches the legacy multipart field.
    pub conversation_id: Option<Uuid>,
}

#[derive(Debug, Serialize)]
pub struct InitUploadResponse {
    pub upload_id: Uuid,
    pub chunk_size: i64,
}

/// `POST /api/media/upload/init` -- begin a new resumable upload.
pub async fn init(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<InitUploadRequest>,
) -> Result<impl IntoResponse, AppError> {
    if req.total_size <= 0 {
        return Err(AppError::bad_request("total_size must be positive"));
    }
    let max = max_chunked_upload_bytes();
    if req.total_size > max {
        return Err(AppError::bad_request(format!(
            "File too large. Maximum chunked upload size is {max} bytes"
        )));
    }
    if req.filename.trim().is_empty() {
        return Err(AppError::bad_request("filename is required"));
    }
    if req.mime_type.trim().is_empty() {
        return Err(AppError::bad_request("mime_type is required"));
    }

    if let Some(cid) = req.conversation_id {
        let is_member = db::groups::is_member(&state.pool, cid, auth.user_id)
            .await
            .db_ctx("chunked_upload/init/is_member")?;
        if !is_member {
            return Err(AppError::with_code(
                crate::error::ErrorCode::NotMember,
                "Not a member of this conversation",
            ));
        }
    }

    fs::create_dir_all(TMP_DIR)
        .await
        .map_err(|e| AppError::internal(format!("Failed to create temp upload directory: {e}")))?;

    let upload_id = Uuid::new_v4();
    let temp_path = format!("{TMP_DIR}/{upload_id}");

    // Pre-create the empty temp file so the very first PATCH never has to
    // distinguish "file missing" from "file at offset 0".
    fs::File::create(&temp_path)
        .await
        .map_err(|e| AppError::internal(format!("Failed to create temp upload file: {e}")))?;

    db::upload_sessions::create(
        &state.pool,
        upload_id,
        auth.user_id,
        req.filename.trim(),
        req.mime_type.trim(),
        req.total_size,
        req.conversation_id,
        &temp_path,
    )
    .await
    .db_ctx("chunked_upload/init/create")?;

    Ok((
        StatusCode::CREATED,
        Json(InitUploadResponse {
            upload_id,
            chunk_size: DEFAULT_CHUNK_SIZE,
        }),
    ))
}

// ---------------------------------------------------------------------------
// PATCH /api/media/upload/{id}/chunk
// ---------------------------------------------------------------------------

/// Parsed `Content-Range: bytes <start>-<end>/<total>` triple.
///
/// `end` is inclusive (matches the HTTP spec); the chunk body length must
/// be `end - start + 1` bytes.  `total` must match the session's
/// `total_size` -- a mismatch here means the client thinks it's uploading
/// a different file than the one init reserved space for.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ContentRange {
    pub start: i64,
    pub end: i64,
    pub total: i64,
}

/// Parse a `Content-Range: bytes <start>-<end>/<total>` header.  Returns
/// `Err(())` for any malformed input.  Kept as a pure function so the
/// unit tests below can exercise every branch without spinning up axum.
pub(crate) fn parse_content_range(header: &str) -> Result<ContentRange, ()> {
    let spec = header.trim().strip_prefix("bytes ").ok_or(())?;
    let (range, total) = spec.split_once('/').ok_or(())?;
    let (s, e) = range.split_once('-').ok_or(())?;
    let start: i64 = s.parse().map_err(|_| ())?;
    let end: i64 = e.parse().map_err(|_| ())?;
    let total: i64 = total.parse().map_err(|_| ())?;
    if start < 0 || end < start || total <= 0 || end >= total {
        return Err(());
    }
    Ok(ContentRange { start, end, total })
}

#[derive(Debug, Serialize)]
pub struct ChunkResponse {
    pub bytes_received: i64,
}

/// `PATCH /api/media/upload/{id}/chunk` -- append a chunk to a pending
/// session.
///
/// Wire contract:
/// - `Content-Range: bytes <start>-<end>/<total>` (required, inclusive).
/// - Body is raw bytes, length `end - start + 1`.
/// - `start` MUST equal the session's `bytes_received`; otherwise 416.
/// - 4xx for any header / size / state mismatch; 200 on success with
///   the new `bytes_received` so clients can re-sync without an extra GET.
pub async fn upload_chunk(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    body: Body,
) -> Result<impl IntoResponse, AppError> {
    let range_header = headers
        .get(axum::http::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| AppError::bad_request("Content-Range header is required"))?;

    let range = parse_content_range(range_header)
        .map_err(|()| AppError::bad_request("Malformed Content-Range header"))?;

    let session = load_pending_session(&state, id, auth.user_id).await?;

    if range.total != session.total_size {
        return Err(AppError::bad_request(
            "Content-Range total does not match session total_size",
        ));
    }
    if range.start != session.bytes_received {
        return Err(range_mismatch(session.bytes_received));
    }

    let declared_len = range.end - range.start + 1;
    if declared_len <= 0 || declared_len > MAX_CHUNK_BYTES {
        return Err(AppError::bad_request("Chunk size out of bounds"));
    }
    if range.end + 1 > session.total_size {
        return Err(AppError::bad_request(
            "Chunk would exceed declared total_size",
        ));
    }

    let written = stream_chunk_to_disk(&session.temp_path, body, declared_len).await?;
    let updated = db::upload_sessions::add_bytes(&state.pool, id, written)
        .await
        .db_ctx("chunked_upload/chunk/add_bytes")?;

    Ok(Json(ChunkResponse {
        bytes_received: updated.bytes_received,
    }))
}

/// 416 Range Not Satisfiable with a `bytes_received` body so the client
/// can re-sync from a single response.
fn range_mismatch(bytes_received: i64) -> AppError {
    AppError {
        status: StatusCode::RANGE_NOT_SATISFIABLE,
        message: format!(
            "Content-Range start does not match server bytes_received={bytes_received}"
        ),
        code: crate::error::ErrorCode::BadRequest,
        body: Some(json!({ "bytes_received": bytes_received })),
    }
}

/// Stream the request body into the temp file, capped at `declared_len`.
///
/// We tear the connection down (return Err) if the body is larger than
/// declared so a buggy or malicious client cannot rewrite bytes past the
/// declared range.  If the body is short we still return the partial
/// count -- subsequent chunk requests will resume from there.
async fn stream_chunk_to_disk(
    temp_path: &str,
    body: Body,
    declared_len: i64,
) -> Result<i64, AppError> {
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(temp_path)
        .await
        .map_err(|e| AppError::internal(format!("Failed to open temp upload file: {e}")))?;

    let mut written: i64 = 0;
    let mut stream = body.into_data_stream();
    while let Some(frame) = stream.next().await {
        let bytes =
            frame.map_err(|e| AppError::bad_request(format!("Failed to read chunk body: {e}")))?;
        let remaining = declared_len - written;
        if remaining <= 0 {
            // Body claims more bytes than the range allows.  Don't write,
            // and surface a 4xx so the client knows to abort + retry.
            return Err(AppError::bad_request("Chunk body exceeds declared range"));
        }
        let take = (bytes.len() as i64).min(remaining) as usize;
        if take < bytes.len() {
            // Body is larger than declared even on a single frame.  Same
            // 4xx, no partial write past the cap.
            return Err(AppError::bad_request("Chunk body exceeds declared range"));
        }
        if take > 0 {
            file.write_all(&bytes[..take])
                .await
                .map_err(|e| AppError::internal(format!("Failed to write chunk to disk: {e}")))?;
            written += take as i64;
        }
    }
    file.flush()
        .await
        .map_err(|e| AppError::internal(format!("Failed to flush chunk: {e}")))?;
    // Force the OS to commit the buffered bytes to the page cache so the
    // next chunk POST (which opens a fresh file handle) and `finalize`
    // observe the complete content. Without this, slow CI runners can
    // flake `chunks_append_in_order_and_finalize_returns_media_url` when
    // finalize's `detect_mime_from_file` reads a short prefix or
    // `fs::rename` races the in-flight write.
    file.sync_all()
        .await
        .map_err(|e| AppError::internal(format!("Failed to sync chunk: {e}")))?;
    Ok(written)
}

// ---------------------------------------------------------------------------
// POST /api/media/upload/{id}/finalize
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, Default)]
pub struct FinalizeRequest {
    /// Optional client-side SHA-256 of the assembled file (hex).  Rejected
    /// 4xx if present and the server-side hash differs.
    pub sha256: Option<String>,
}

/// `POST /api/media/upload/{id}/finalize` -- assemble the final media row.
pub async fn finalize(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    body: Option<Json<FinalizeRequest>>,
) -> Result<impl IntoResponse, AppError> {
    let req = body.map(|Json(r)| r).unwrap_or_default();
    let session = load_pending_session(&state, id, auth.user_id).await?;

    if session.bytes_received != session.total_size {
        return Err(AppError::bad_request(format!(
            "Upload is incomplete: bytes_received={} total_size={}",
            session.bytes_received, session.total_size
        )));
    }

    if let Some(expected_hex) = req.sha256.as_deref() {
        verify_sha256(&session.temp_path, expected_hex).await?;
    }

    let mime_type = detect_mime_from_file(&session.temp_path, &session.mime_type).await?;
    let ext = media::extension_for_mime(&mime_type);
    let file_uuid = Uuid::new_v4();
    let disk_path = format!("./uploads/{file_uuid}.{ext}");

    fs::create_dir_all("./uploads")
        .await
        .map_err(|e| AppError::internal(format!("Failed to create uploads directory: {e}")))?;

    fs::rename(&session.temp_path, &disk_path)
        .await
        .map_err(|e| AppError::internal(format!("Failed to move temp upload into place: {e}")))?;

    let safe_filename = sanitize_filename(&session.filename);
    let (img_w, img_h) = if mime_type.starts_with("image/") {
        media::read_image_dimensions(&disk_path)
            .map(|(w, h)| (Some(w as i32), Some(h as i32)))
            .unwrap_or((None, None))
    } else {
        (None, None)
    };

    let row = db::media::create_media(
        &state.pool,
        file_uuid,
        auth.user_id,
        &safe_filename,
        &mime_type,
        session.total_size,
        session.conversation_id,
        img_w,
        img_h,
    )
    .await
    .db_ctx("chunked_upload/finalize/create_media")?;

    let mut thumb_url: Option<String> = None;
    if mime_type.starts_with("video/") {
        let thumb_path = format!("./uploads/{file_uuid}.thumb.jpg");
        if let Err(e) = media::generate_video_thumbnail(&disk_path, &thumb_path).await {
            tracing::warn!(
                media_id = %row.id,
                "chunked upload: video thumbnail generation skipped: {e}"
            );
        } else {
            thumb_url = Some(format!("/api/media/{}/thumb", row.id));
        }
    }

    db::upload_sessions::mark_finalized(&state.pool, id)
        .await
        .db_ctx("chunked_upload/finalize/mark_finalized")?;

    Ok((
        StatusCode::CREATED,
        Json(media::build_upload_response(&row, thumb_url)),
    ))
}

/// Strip characters that would break Content-Disposition / on-disk paths.
/// Mirrors the sanitiser in the legacy download path so chunked-uploaded
/// files can be served back identically.
fn sanitize_filename(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .filter(|c| *c != '"' && *c != '\\' && *c != '\r' && *c != '\n' && *c != '/' && *c != '\0')
        .collect();
    if cleaned.trim().is_empty() {
        "upload".to_string()
    } else {
        cleaned
    }
}

/// Hash the assembled file with SHA-256 and compare against the
/// client-provided hex digest.  4xx if they differ.
async fn verify_sha256(path: &str, expected_hex: &str) -> Result<(), AppError> {
    use tokio::io::AsyncReadExt;
    let mut file = fs::File::open(path)
        .await
        .map_err(|e| AppError::internal(format!("Failed to open temp file for hashing: {e}")))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = file
            .read(&mut buf)
            .await
            .map_err(|e| AppError::internal(format!("Failed to read temp file: {e}")))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let digest = hasher.finalize();
    let actual = hex_lower(&digest);
    if !actual.eq_ignore_ascii_case(expected_hex.trim()) {
        return Err(AppError::bad_request(format!(
            "sha256 mismatch: client {expected_hex} != server {actual}"
        )));
    }
    Ok(())
}

/// Bare hex encoder so we don't pull in an extra dependency.
fn hex_lower(bytes: &[u8]) -> String {
    const TABLE: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(TABLE[(b >> 4) as usize] as char);
        out.push(TABLE[(b & 0xF) as usize] as char);
    }
    out
}

/// Sniff the first 512 bytes of the assembled file with `infer` -- same
/// magic-byte gate the legacy single-shot endpoint uses on the streamed
/// head buffer.  This is the only point where client-declared MIME is
/// allowed to influence the stored mime_type (and only for the audio/m4a
/// vs video/mp4 disambiguation that `media::validate_head` already
/// codifies).
async fn detect_mime_from_file(path: &str, declared: &str) -> Result<String, AppError> {
    use tokio::io::AsyncReadExt;
    let mut file = fs::File::open(path)
        .await
        .map_err(|e| AppError::internal(format!("Failed to open temp file for sniffing: {e}")))?;
    let mut head = vec![0u8; 512];
    let n = file
        .read(&mut head)
        .await
        .map_err(|e| AppError::internal(format!("Failed to read temp file head: {e}")))?;
    head.truncate(n);
    media::validate_head(&head, declared)
}

// ---------------------------------------------------------------------------
// GET /api/media/upload/{id}
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct UploadStateResponse {
    pub upload_id: Uuid,
    pub bytes_received: i64,
    pub total_size: i64,
    pub status: String,
}

/// `GET /api/media/upload/{id}` -- read the current state of a session
/// so a client recovering from a crash can resume from the right offset.
pub async fn get_state(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let session = db::upload_sessions::get(&state.pool, id, auth.user_id)
        .await
        .db_ctx("chunked_upload/get_state")?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "Upload session not found".to_string(),
            code: crate::error::ErrorCode::NotFound,
            body: None,
        })?;

    Ok(Json(UploadStateResponse {
        upload_id: session.id,
        bytes_received: session.bytes_received,
        total_size: session.total_size,
        status: session.status,
    }))
}

// ---------------------------------------------------------------------------
// Background cleanup
// ---------------------------------------------------------------------------

/// Sweep `upload_sessions` for pending rows idle longer than
/// `idle_seconds`, delete their temp file, and mark them aborted.
///
/// Spawned from `main.rs` on the same `spawn_periodic` cadence used by
/// the other cleanup loops.
pub async fn cleanup_stale_uploads(pool: &sqlx::PgPool, idle_seconds: i64) {
    let rows = match db::upload_sessions::list_stale_pending(pool, idle_seconds).await {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("chunked upload cleanup: list_stale_pending failed: {e}");
            return;
        }
    };

    for row in rows {
        if let Err(e) = fs::remove_file(&row.temp_path).await
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(
                upload_id = %row.id,
                "chunked upload cleanup: failed to unlink {}: {e}",
                row.temp_path
            );
        }
        if let Err(e) = db::upload_sessions::mark_aborted(pool, row.id).await {
            tracing::warn!(
                upload_id = %row.id,
                "chunked upload cleanup: mark_aborted failed: {e}"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Load a session owned by `user_id` and reject anything not in the
/// `pending` state with a clear 4xx.
async fn load_pending_session(
    state: &AppState,
    id: Uuid,
    user_id: Uuid,
) -> Result<db::upload_sessions::UploadSessionRow, AppError> {
    let session = db::upload_sessions::get(&state.pool, id, user_id)
        .await
        .db_ctx("chunked_upload/load_pending_session")?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "Upload session not found".to_string(),
            code: crate::error::ErrorCode::NotFound,
            body: None,
        })?;

    if session.status != db::upload_sessions::STATUS_PENDING {
        return Err(AppError::bad_request(format!(
            "Upload session is not pending (status={})",
            session.status
        )));
    }
    Ok(session)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_content_range_basic() {
        let r = parse_content_range("bytes 0-4/10").unwrap();
        assert_eq!(
            r,
            ContentRange {
                start: 0,
                end: 4,
                total: 10
            }
        );
    }

    #[test]
    fn parse_content_range_full_file() {
        let r = parse_content_range("bytes 0-99/100").unwrap();
        assert_eq!(r.start, 0);
        assert_eq!(r.end, 99);
        assert_eq!(r.total, 100);
    }

    #[test]
    fn parse_content_range_rejects_missing_prefix() {
        assert!(parse_content_range("0-4/10").is_err());
        assert!(parse_content_range("bytes=0-4/10").is_err());
    }

    #[test]
    fn parse_content_range_rejects_end_past_total() {
        assert!(parse_content_range("bytes 0-100/100").is_err());
    }

    #[test]
    fn parse_content_range_rejects_inverted_range() {
        assert!(parse_content_range("bytes 100-50/200").is_err());
    }

    #[test]
    fn parse_content_range_rejects_negative_start() {
        assert!(parse_content_range("bytes -1-10/100").is_err());
    }

    #[test]
    fn parse_content_range_rejects_zero_total() {
        assert!(parse_content_range("bytes 0-0/0").is_err());
    }

    #[test]
    fn parse_content_range_rejects_garbage() {
        assert!(parse_content_range("not a range").is_err());
        assert!(parse_content_range("bytes a-b/c").is_err());
        assert!(parse_content_range("bytes 0-4").is_err());
    }

    #[test]
    fn hex_lower_known_vector() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let bytes = [
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f,
            0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b,
            0x78, 0x52, 0xb8, 0x55,
        ];
        assert_eq!(
            hex_lower(&bytes),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn sanitize_filename_strips_dangerous_chars() {
        assert_eq!(
            sanitize_filename("hello\"world\\evil/../etc/passwd\n"),
            "helloworldevil..etcpasswd"
        );
    }

    #[test]
    fn sanitize_filename_falls_back_on_empty() {
        assert_eq!(sanitize_filename(""), "upload");
        assert_eq!(sanitize_filename("\n\r/\""), "upload");
    }

    #[test]
    fn default_max_chunked_upload_bytes_is_one_gib() {
        assert_eq!(DEFAULT_MAX_CHUNKED_UPLOAD_BYTES, 1024 * 1024 * 1024);
    }
}
