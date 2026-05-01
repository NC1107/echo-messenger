//! Integration tests for media upload / download / ticket endpoints.

mod common;

use reqwest::Client;
use reqwest::multipart::{Form, Part};
use serde_json::Value;

/// 3 MB synthetic MP4 -- valid `ftyp` header that `infer` detects as video/mp4,
/// padded to exceed Axum's default 2 MB body limit.
const SYNTHETIC_MP4_SIZE: usize = 3 * 1024 * 1024;

/// 50 MB synthetic MP4 -- exercises the streaming upload path (#680).
const LARGE_MP4_SIZE: usize = 50 * 1024 * 1024;

/// 101 MB synthetic MP4 -- one byte over `MAX_FILE_SIZE` (100 MB).
/// The server must reject this before writing the full payload to disk.
const OVERSIZED_MP4_SIZE: usize = 101 * 1024 * 1024;

fn make_minimal_mp4(size: usize) -> Vec<u8> {
    // Minimal ISO Base Media (ftyp) box: size(4) + "ftyp"(4) + "isom"(4)
    // + minor_version(4) + compatible_brand(4) = 20 bytes total.
    let mut data = vec![
        0x00, 0x00, 0x00, 0x14, // box size = 20
        b'f', b't', b'y', b'p', // box type = "ftyp"
        b'i', b's', b'o', b'm', // major brand  = "isom"
        0x00, 0x00, 0x00, 0x00, // minor version = 0
        b'i', b's', b'o', b'm', // compatible brand = "isom"
    ];
    data.resize(size, 0);
    data
}

/// 1x1 pixel PNG -- enough for `infer::get` to detect image/png.
const MINIMAL_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// Minimal ELF header -- a disallowed file type.
const ELF_BYTES: &[u8] = b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Upload MINIMAL_PNG and return `(media_id, url)`.
async fn upload_png(client: &Client, base: &str, token: &str) -> (String, String) {
    let part = Part::bytes(MINIMAL_PNG.to_vec())
        .file_name("test.png")
        .mime_str("image/png")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201, "upload should return 201");
    let body: Value = resp.json().await.unwrap();
    let id = body["id"].as_str().unwrap().to_string();
    let url = body["url"].as_str().unwrap().to_string();
    (id, url)
}

/// Obtain a single-use media ticket.
async fn get_media_ticket(client: &Client, base: &str, token: &str) -> String {
    let resp = client
        .post(format!("{base}/api/media/ticket"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200, "ticket endpoint should 200");
    let body: Value = resp.json().await.unwrap();
    body["ticket"].as_str().unwrap().to_string()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn upload_with_valid_auth_returns_201() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_up").await;

    let (id, url) = upload_png(&client, &base, &token).await;
    assert!(!id.is_empty(), "response should contain an id");
    assert!(
        url.contains(&id),
        "url should reference the media id: {url}"
    );
}

#[tokio::test]
async fn upload_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let part = Part::bytes(MINIMAL_PNG.to_vec())
        .file_name("test.png")
        .mime_str("image/png")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn upload_disallowed_mime_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_elf").await;

    let part = Part::bytes(ELF_BYTES.to_vec())
        .file_name("evil.elf")
        .mime_str("application/octet-stream")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body = resp.text().await.unwrap();
    assert!(
        body.contains("not allowed") || body.contains("Could not detect"),
        "body should mention disallowed type: {body}"
    );
}

#[tokio::test]
async fn download_with_bearer_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_dl").await;

    let (id, _) = upload_png(&client, &base, &token).await;

    let resp = client
        .get(format!("{base}/api/media/{id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let content_type = resp
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert_eq!(content_type, "image/png");

    let bytes = resp.bytes().await.unwrap();
    assert_eq!(bytes.as_ref(), MINIMAL_PNG, "downloaded bytes should match");
}

#[tokio::test]
async fn download_with_ticket_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_tkt").await;

    let (id, _) = upload_png(&client, &base, &token).await;
    let ticket = get_media_ticket(&client, &base, &token).await;

    let resp = client
        .get(format!("{base}/api/media/{id}?ticket={ticket}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let bytes = resp.bytes().await.unwrap();
    assert_eq!(bytes.as_ref(), MINIMAL_PNG);
}

#[tokio::test]
async fn download_with_invalid_ticket_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_bad").await;

    let (id, _) = upload_png(&client, &base, &token).await;

    let resp = client
        .get(format!("{base}/api/media/{id}?ticket=bogus"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn ticket_is_reusable_within_ttl() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_once").await;

    let (id, _) = upload_png(&client, &base, &token).await;
    let ticket = get_media_ticket(&client, &base, &token).await;

    // First use -- should succeed
    let resp = client
        .get(format!("{base}/api/media/{id}?ticket={ticket}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Second use -- tickets are reusable within their 5-min TTL
    // (web <img> tags need to reuse the same ticket for multiple images)
    let resp = client
        .get(format!("{base}/api/media/{id}?ticket={ticket}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn download_nonexistent_media_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_404").await;

    let random_uuid = uuid::Uuid::new_v4();
    let resp = client
        .get(format!("{base}/api/media/{random_uuid}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn upload_with_empty_form_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_empty").await;

    // Send multipart with no file field -- just an unrelated text part
    let form = Form::new().text("not_a_file", "hello");

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body = resp.text().await.unwrap();
    assert!(
        body.contains("Missing 'file' field"),
        "body should mention missing file field: {body}"
    );
}

#[tokio::test]
async fn legacy_token_param_works() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_leg").await;

    let (id, _) = upload_png(&client, &base, &token).await;
    let ticket = get_media_ticket(&client, &base, &token).await;

    // Use ?token= instead of ?ticket=
    let resp = client
        .get(format!("{base}/api/media/{id}?token={ticket}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let bytes = resp.bytes().await.unwrap();
    assert_eq!(bytes.as_ref(), MINIMAL_PNG);
}

// ---------------------------------------------------------------------------
// Ticket auth-flow coverage -- #539
// ---------------------------------------------------------------------------

#[tokio::test]
async fn ticket_endpoint_without_auth_returns_401() {
    // POST /api/media/ticket requires a valid JWT; unauthenticated callers
    // must be rejected so anonymous clients can't pre-mint tickets.
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/media/ticket"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn ticket_issued_to_user_a_cannot_download_media_owned_by_user_b() {
    // Cross-user ticket isolation: a ticket minted for user A should not
    // grant access to media that user B uploaded and that A has no ACL on.
    // (The server ACL check runs after ticket validation.)
    let base = common::spawn_server().await;
    let client = Client::new();

    // User A uploads a file.
    let (token_a, _, _) = common::register_and_login(&client, &base, "media_xuser_a").await;
    let (id_a, _) = upload_png(&client, &base, &token_a).await;

    // User B gets a ticket (valid, but scoped to B's session).
    let (token_b, _, _) = common::register_and_login(&client, &base, "media_xuser_b").await;
    let ticket_b = get_media_ticket(&client, &base, &token_b).await;

    // B's ticket must not grant access to A's private media (no shared contact).
    let resp = client
        .get(format!("{base}/api/media/{id_a}?ticket={ticket_b}"))
        .send()
        .await
        .unwrap();

    // The server returns 404 (not 403) to avoid revealing that the file
    // exists to an unauthorized caller -- security by obscurity, by design.
    assert!(
        matches!(resp.status().as_u16(), 401 | 403 | 404),
        "cross-user ticket download should be denied (401/403/404), got {}",
        resp.status()
    );
}

#[tokio::test]
async fn upload_video_larger_than_2mb_returns_201() {
    // Regression test: Axum's default body limit is 2 MB, but the server's
    // own MAX_FILE_SIZE is 10 MB.  Without an explicit DefaultBodyLimit
    // override on the upload route, any video > 2 MB was rejected (413).
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_vid").await;

    let video_bytes = make_minimal_mp4(SYNTHETIC_MP4_SIZE);
    let part = Part::bytes(video_bytes)
        .file_name("test.mp4")
        .mime_str("video/mp4")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    assert_eq!(
        resp.status().as_u16(),
        201,
        "video upload should succeed: body = {}",
        resp.text().await.unwrap_or_default()
    );
}

#[tokio::test]
async fn streaming_upload_50mb_returns_201() {
    // Validates the streaming upload path (#680): a 50 MB file must be
    // accepted and persisted without buffering the full payload into RAM.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_50m").await;

    let video_bytes = make_minimal_mp4(LARGE_MP4_SIZE);
    assert_eq!(video_bytes.len(), LARGE_MP4_SIZE);

    let part = Part::bytes(video_bytes)
        .file_name("large.mp4")
        .mime_str("video/mp4")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    assert_eq!(
        resp.status().as_u16(),
        201,
        "50 MB streaming upload should succeed: body = {}",
        resp.text().await.unwrap_or_default()
    );
}

#[tokio::test]
async fn streaming_upload_oversized_returns_400() {
    // Validates the streaming size guard (#680): a payload exceeding
    // MAX_FILE_SIZE (100 MB) must be rejected before the full payload
    // lands on disk.  The server aborts mid-stream and returns 400.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_101m").await;

    let video_bytes = make_minimal_mp4(OVERSIZED_MP4_SIZE);
    assert_eq!(video_bytes.len(), OVERSIZED_MP4_SIZE);

    let part = Part::bytes(video_bytes)
        .file_name("toobig.mp4")
        .mime_str("video/mp4")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    let status = resp.status().as_u16();
    let body = resp.text().await.unwrap_or_default();
    // The server rejects oversized uploads with 400 (streaming byte counter)
    // or 413 (axum DefaultBodyLimit layer), depending on which guard fires first.
    assert!(
        status == 400 || status == 413,
        "oversized upload should be rejected with 400 or 413, got {status}: body = {body}"
    );
}

// ---------------------------------------------------------------------------
// M4V regression test -- #411
// ---------------------------------------------------------------------------

/// Build a minimal M4V ftyp box padded to 3 MB so Axum's default 2 MB body
/// limit is also exercised (ensuring the route's DefaultBodyLimit override is
/// in effect for M4V as well).
fn make_minimal_m4v(size: usize) -> Vec<u8> {
    let mut data = vec![
        0x00, 0x00, 0x00, 0x14, // box size = 20
        b'f', b't', b'y', b'p', // box type = "ftyp"
        b'M', b'4', b'V', b' ', // major brand = "M4V "
        0x00, 0x00, 0x00, 0x00, // minor version
        b'M', b'4', b'V', b' ', // compatible brand
    ];
    data.resize(size, 0);
    data
}

#[tokio::test]
async fn upload_m4v_returns_201() {
    // Regression for #411: Apple M4V files (ftyp brand "M4V ") were rejected
    // with 400 "Detected file type 'video/x-m4v' is not allowed" because
    // "video/x-m4v" was missing from the server's ALLOWED_MIME_TYPES list.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _, _) = common::register_and_login(&client, &base, "media_m4v").await;

    let m4v_bytes = make_minimal_m4v(SYNTHETIC_MP4_SIZE);
    let part = Part::bytes(m4v_bytes)
        .file_name("clip.m4v")
        .mime_str("video/mp4")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .post(format!("{base}/api/media/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();

    assert_eq!(
        resp.status().as_u16(),
        201,
        "M4V upload should succeed: body = {}",
        resp.text().await.unwrap_or_default()
    );
}
