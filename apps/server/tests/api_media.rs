//! Integration tests for media upload / download / ticket endpoints.

mod common;

use reqwest::Client;
use reqwest::multipart::{Form, Part};
use serde_json::Value;

/// 3 MB synthetic MP4 -- valid `ftyp` header that `infer` detects as video/mp4,
/// padded to exceed Axum's default 2 MB body limit.
const SYNTHETIC_MP4_SIZE: usize = 3 * 1024 * 1024;

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
