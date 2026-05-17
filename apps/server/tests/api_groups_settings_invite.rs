//! Integration tests for group settings (update_group, upload_group_avatar,
//! get_group_avatar) and invite-link endpoints (create_invite, list_invites,
//! get_invite_preview, accept_invite, revoke_invite).

mod common;

use reqwest::Client;
use reqwest::multipart::{Form, Part};
use serde_json::Value;

// ---------------------------------------------------------------------------
// 1x1 pixel PNG -- same bytes used in api_media tests; `infer` detects image/png.
// ---------------------------------------------------------------------------
const MINIMAL_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
];

// Minimal ELF header -- not in the allowed MIME list.
const ELF_BYTES: &[u8] = b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00";

// A 3-byte payload that `infer` cannot identify.
const UNRECOGNIZED_BYTES: &[u8] = &[0xAA, 0xBB, 0xCC];

// ---------------------------------------------------------------------------
// Local helpers
// ---------------------------------------------------------------------------

async fn register_and_login(client: &Client, base: &str, prefix: &str) -> (String, String) {
    let username = common::unique_username(prefix);
    common::register(client, base, &username, "password123").await;
    common::login(client, base, &username, "password123").await
}

async fn create_group(client: &Client, base: &str, token: &str, name: &str) -> String {
    let resp = client
        .post(format!("{base}/api/groups"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "name": name }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "create_group must return 201");
    let body: Value = resp.json().await.unwrap();
    body["id"].as_str().unwrap().to_string()
}

async fn create_invite_helper(
    client: &Client,
    base: &str,
    auth_token: &str,
    group_id: &str,
) -> String {
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {auth_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201, "create_invite must return 201");
    let body: Value = resp.json().await.unwrap();
    body["token"].as_str().unwrap().to_string()
}

// ---------------------------------------------------------------------------
// update_group
// ---------------------------------------------------------------------------

#[tokio::test]
async fn update_group_owner_can_change_title() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "upd_title_own").await;
    let group_id = create_group(&client, &base, &token, "OrigTitle").await;

    let resp = client
        .put(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "title": "RenamedTitle" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "updated");

    // Verify the new title persisted.
    let get: Value = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(get["title"].as_str(), Some("RenamedTitle"));
}

#[tokio::test]
async fn update_group_owner_can_change_description() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "upd_desc_own").await;
    let group_id = create_group(&client, &base, &token, "DescGroup").await;

    let resp = client
        .put(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "description": "A helpful description" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn update_group_non_admin_member_gets_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "upd_own403").await;
    let (member_token, member_id) = register_and_login(&client, &base, "upd_mem403").await;
    let group_id = create_group(&client, &base, &owner_token, "ForbiddenUpdate").await;

    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    let resp = client
        .put(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {member_token}"))
        .json(&serde_json::json!({ "title": "HijackedName" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn update_group_non_member_gets_error() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "upd_own_nm").await;
    let (stranger_token, _) = register_and_login(&client, &base, "upd_str_nm").await;
    let group_id = create_group(&client, &base, &owner_token, "StrangerGroup").await;

    let resp = client
        .put(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .json(&serde_json::json!({ "title": "NotAllowed" }))
        .send()
        .await
        .unwrap();
    // Non-member: the route returns 4xx (401 or 403 depending on impl).
    assert!(
        resp.status().as_u16() >= 400,
        "non-member update should be rejected"
    );
}

#[tokio::test]
async fn update_group_empty_title_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "upd_empty_ttl").await;
    let group_id = create_group(&client, &base, &token, "ValidGroup").await;

    let resp = client
        .put(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "title": "   " }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// upload_group_avatar
// ---------------------------------------------------------------------------

#[tokio::test]
async fn upload_group_avatar_owner_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_up_own").await;
    let group_id = create_group(&client, &base, &token, "AvatarGroup").await;

    let part = Part::bytes(MINIMAL_PNG.to_vec())
        .file_name("avatar.png")
        .mime_str("image/png")
        .unwrap();
    let form = Form::new().part("avatar", part);

    let resp = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "avatar upload should return 200"
    );
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["avatar_url"]
            .as_str()
            .unwrap_or("")
            .contains(&group_id),
        "avatar_url should reference the group id"
    );
}

#[tokio::test]
async fn upload_group_avatar_file_field_name_also_accepted() {
    // The endpoint accepts either "avatar" or "file" as the multipart field name.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_file_field").await;
    let group_id = create_group(&client, &base, &token, "AvatarFileFld").await;

    let part = Part::bytes(MINIMAL_PNG.to_vec())
        .file_name("avatar.png")
        .mime_str("image/png")
        .unwrap();
    let form = Form::new().part("file", part);

    let resp = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn upload_group_avatar_non_admin_gets_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "gav_own_403").await;
    let (member_token, member_id) = register_and_login(&client, &base, "gav_mem_403").await;
    let group_id = create_group(&client, &base, &owner_token, "AvatarForbidGroup").await;

    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    let part = Part::bytes(MINIMAL_PNG.to_vec())
        .file_name("avatar.png")
        .mime_str("image/png")
        .unwrap();
    let form = Form::new().part("avatar", part);

    let resp = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {member_token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn upload_group_avatar_disallowed_mime_returns_error() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_mime_bad").await;
    let group_id = create_group(&client, &base, &token, "AvatarBadMime").await;

    let part = Part::bytes(ELF_BYTES.to_vec())
        .file_name("evil.elf")
        .mime_str("application/octet-stream")
        .unwrap();
    let form = Form::new().part("avatar", part);

    let resp = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    assert!(
        status == 400 || status == 415 || status == 422,
        "disallowed MIME should be rejected, got {status}"
    );
}

#[tokio::test]
async fn upload_group_avatar_unrecognized_bytes_returns_error() {
    // `infer` cannot identify the bytes → server must reject with a type error.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_unrec").await;
    let group_id = create_group(&client, &base, &token, "AvatarUnrecGroup").await;

    let part = Part::bytes(UNRECOGNIZED_BYTES.to_vec())
        .file_name("junk.bin")
        .mime_str("application/octet-stream")
        .unwrap();
    let form = Form::new().part("avatar", part);

    let resp = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    assert!(
        status >= 400,
        "unrecognized bytes should be rejected, got {status}"
    );
}

#[tokio::test]
async fn upload_group_avatar_oversized_returns_error() {
    // 3 MB PNG-shaped payload (magic bytes present) exceeds the 2 MB group
    // avatar cap. The server must reject it.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_big").await;
    let group_id = create_group(&client, &base, &token, "AvatarBigGroup").await;

    // Build a 3 MB buffer that starts with PNG magic bytes so `infer`
    // detects it as image/png, but the size check fires first.
    let mut big_png = MINIMAL_PNG.to_vec();
    big_png.resize(3 * 1024 * 1024, 0);

    let part = Part::bytes(big_png)
        .file_name("big.png")
        .mime_str("image/png")
        .unwrap();
    let form = Form::new().part("avatar", part);

    let resp = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    assert!(
        status == 400 || status == 413,
        "oversized avatar should be rejected with 400 or 413, got {status}"
    );
}

#[tokio::test]
async fn upload_group_avatar_missing_field_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_no_fld").await;
    let group_id = create_group(&client, &base, &token, "AvatarNoField").await;

    // Send multipart with an unrecognised field name.
    let form = Form::new().text("not_avatar", "ignored");

    let resp = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// get_group_avatar
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_group_avatar_returns_stored_image() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_get_ok").await;
    let group_id = create_group(&client, &base, &token, "AvatarGetGroup").await;

    // Upload first.
    let part = Part::bytes(MINIMAL_PNG.to_vec())
        .file_name("avatar.png")
        .mime_str("image/png")
        .unwrap();
    let form = Form::new().part("avatar", part);
    let up = client
        .put(format!("{base}/api/groups/{group_id}/avatar"))
        .header("Authorization", format!("Bearer {token}"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    assert_eq!(up.status().as_u16(), 200);

    // Fetch without auth (public endpoint).
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/avatar"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let ct = resp
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert_eq!(ct, "image/png");
    let bytes = resp.bytes().await.unwrap();
    assert_eq!(bytes.as_ref(), MINIMAL_PNG);
}

#[tokio::test]
async fn get_group_avatar_no_avatar_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gav_get_404").await;
    let group_id = create_group(&client, &base, &token, "AvatarNone404").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/avatar"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

// ---------------------------------------------------------------------------
// create_invite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_invite_returns_201_token_and_url() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "si_creat").await;
    let group_id = create_group(&client, &base, &token, "CreateInvGrp").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let inv_token = body["token"].as_str().expect("missing token");
    let url = body["url"].as_str().expect("missing url");
    assert!(!inv_token.is_empty(), "token must be non-empty");
    assert!(url.contains(inv_token), "url must embed the token");
}

#[tokio::test]
async fn create_invite_with_max_uses_reflects_in_response() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "si_maxuses").await;
    let group_id = create_group(&client, &base, &token, "MaxUsesInvGrp").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "max_uses": 5 }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["max_uses"].as_i64(), Some(5));
    assert_eq!(body["use_count"].as_i64(), Some(0));
}

#[tokio::test]
async fn create_invite_with_expiry_reflects_expires_at() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "si_expiry").await;
    let group_id = create_group(&client, &base, &token, "ExpiryInvGrp").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "expires_in_seconds": 3600 }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["expires_at"].as_str().is_some(),
        "expires_at must be present when expires_in_seconds is set"
    );
}

#[tokio::test]
async fn create_invite_generates_unique_tokens() {
    // Two separate invites for the same group must have distinct tokens.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "si_uniq").await;
    let group_id = create_group(&client, &base, &token, "UniqTokGrp").await;

    let tok1 = create_invite_helper(&client, &base, &token, &group_id).await;
    let tok2 = create_invite_helper(&client, &base, &token, &group_id).await;
    assert_ne!(tok1, tok2, "two invites must have different tokens");
}

#[tokio::test]
async fn create_invite_non_member_gets_403() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "si_noown").await;
    let (stranger_token, _) = register_and_login(&client, &base, "si_nostr").await;
    let group_id = create_group(&client, &base, &owner_token, "NoMemberInvGrp").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {stranger_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 403);
}

#[tokio::test]
async fn create_invite_regular_member_gets_403() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "si_regown").await;
    let (member_token, member_id) = register_and_login(&client, &base, "si_regmem").await;
    let group_id = create_group(&client, &base, &owner_token, "RegMemberInvGrp").await;

    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 403);
}

// ---------------------------------------------------------------------------
// list_invites
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_invites_returns_only_this_groups_invites() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "li_own").await;
    let group_id = create_group(&client, &base, &owner_token, "ListInvGrp").await;

    // Create two invites for this group.
    let tok1 = create_invite_helper(&client, &base, &owner_token, &group_id).await;
    let tok2 = create_invite_helper(&client, &base, &owner_token, &group_id).await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let list: Vec<Value> = resp.json().await.unwrap();
    let tokens: Vec<&str> = list.iter().filter_map(|i| i["token"].as_str()).collect();
    assert!(tokens.contains(&tok1.as_str()), "tok1 must be listed");
    assert!(tokens.contains(&tok2.as_str()), "tok2 must be listed");
}

#[tokio::test]
async fn list_invites_regular_member_gets_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "li_own401").await;
    let (member_token, member_id) = register_and_login(&client, &base, "li_mem401").await;
    let group_id = create_group(&client, &base, &owner_token, "ListForbidGrp").await;

    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// get_invite_preview
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_invite_preview_valid_token_shows_group_info() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gip_ok").await;
    let group_id = create_group(&client, &base, &token, "PreviewGroup").await;
    let inv_token = create_invite_helper(&client, &base, &token, &group_id).await;

    let resp = client
        .get(format!("{base}/api/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["token"].as_str(), Some(inv_token.as_str()));
    assert_eq!(body["group"]["title"].as_str(), Some("PreviewGroup"));
    assert!(
        body["group"]["member_count"].as_i64().is_some(),
        "preview must include member_count"
    );
}

#[tokio::test]
async fn get_invite_preview_missing_token_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "gip_404").await;

    let resp = client
        .get(format!("{base}/api/invites/totallymadeuptoken"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn get_invite_preview_exhausted_token_returns_error() {
    // Create a max_uses=1 invite, consume it, then preview should fail.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "gip_exh_own").await;
    let (joiner_token, _) = register_and_login(&client, &base, "gip_exh_joi").await;
    let (looker_token, _) = register_and_login(&client, &base, "gip_exh_lk").await;
    let group_id = create_group(&client, &base, &owner_token, "ExhGrpPrev").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "max_uses": 1 }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let inv_token = body["token"].as_str().unwrap().to_string();

    // Use the invite.
    let accept = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(accept.status().as_u16(), 200);

    // Now preview should fail.
    let prev = client
        .get(format!("{base}/api/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {looker_token}"))
        .send()
        .await
        .unwrap();
    assert!(
        prev.status().as_u16() >= 400,
        "exhausted invite preview should be rejected"
    );
}

// ---------------------------------------------------------------------------
// accept_invite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn accept_invite_happy_path_joins_group() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "ai_hp_own").await;
    let (joiner_token, joiner_id) = register_and_login(&client, &base, "ai_hp_joi").await;
    let group_id = create_group(&client, &base, &owner_token, "HappyAccGroup").await;
    let inv_token = create_invite_helper(&client, &base, &owner_token, &group_id).await;

    let resp = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"].as_str(), Some("joined"));

    // Verify joiner is now a member.
    let grp: Value = client
        .get(format!("{base}/api/groups/{group_id}"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let members = grp["members"].as_array().unwrap();
    assert!(
        members
            .iter()
            .any(|m| m["user_id"].as_str() == Some(&joiner_id)),
        "joiner must appear in member list"
    );
}

#[tokio::test]
async fn accept_invite_already_member_returns_already_member() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "ai_alrd_own").await;
    let (joiner_token, _) = register_and_login(&client, &base, "ai_alrd_joi").await;
    let group_id = create_group(&client, &base, &owner_token, "AlreadyMemberGrp").await;
    let inv_token = create_invite_helper(&client, &base, &owner_token, &group_id).await;

    // First accept.
    client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();

    // Second accept -- should return already_member (idempotent).
    let resp = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"].as_str(), Some("already_member"));
}

#[tokio::test]
async fn accept_invite_missing_token_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "ai_miss404").await;

    let resp = client
        .post(format!("{base}/api/invites/doesnotexist/accept"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn accept_invite_max_uses_exhausted_rejects_second() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "ai_exh_own").await;
    let (j1_token, _) = register_and_login(&client, &base, "ai_exh_j1").await;
    let (j2_token, _) = register_and_login(&client, &base, "ai_exh_j2").await;
    let group_id = create_group(&client, &base, &owner_token, "ExhAccGroup").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "max_uses": 1 }))
        .send()
        .await
        .unwrap();
    let inv_token = resp.json::<Value>().await.unwrap()["token"]
        .as_str()
        .unwrap()
        .to_string();

    let r1 = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {j1_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(r1.status().as_u16(), 200);

    let r2 = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {j2_token}"))
        .send()
        .await
        .unwrap();
    assert!(
        r2.status().as_u16() >= 400,
        "second accept on exhausted invite must be rejected"
    );
}

/// #829 TOCTOU: the in-transaction recheck (FOR UPDATE + re-read) must prevent
/// concurrent accepts from exceeding max_uses=1 even when the pre-tx fast-path
/// check passes for both requests simultaneously.
#[tokio::test]
async fn accept_invite_toctou_race_stays_within_max_uses() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "ai_toc_own").await;
    let group_id = create_group(&client, &base, &owner_token, "ToctouAccGrp").await;

    let resp = client
        .post(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "max_uses": 1 }))
        .send()
        .await
        .unwrap();
    let inv_token = resp.json::<Value>().await.unwrap()["token"]
        .as_str()
        .unwrap()
        .to_string();

    // Register two concurrent joiners.
    let mut joiner_tokens = Vec::with_capacity(2);
    for i in 0..2 {
        let (tok, _) = register_and_login(&client, &base, &format!("ai_toc_j{i}")).await;
        joiner_tokens.push(tok);
    }

    let base_arc = std::sync::Arc::new(base.clone());
    let url_path = format!("/api/invites/{inv_token}/accept");
    let mut handles = Vec::with_capacity(joiner_tokens.len());
    for joiner_token in joiner_tokens {
        let base_clone = base_arc.clone();
        let path_clone = url_path.clone();
        let c = client.clone();
        handles.push(tokio::spawn(async move {
            c.post(format!("{base_clone}{path_clone}"))
                .header("Authorization", format!("Bearer {joiner_token}"))
                .send()
                .await
                .map(|r| r.status().as_u16())
        }));
    }

    let mut successes = 0u32;
    let mut rejections = 0u32;
    for h in handles {
        match h.await.unwrap() {
            Ok(200) => successes += 1,
            Ok(400) | Ok(404) => rejections += 1,
            Ok(other) => panic!("unexpected status {other}"),
            Err(e) => panic!("request error: {e}"),
        }
    }

    assert_eq!(successes, 1, "exactly one concurrent accept must succeed");
    assert_eq!(rejections, 1, "the losing accept must be rejected");

    // Confirm use_count in the DB is exactly 1.
    let list: Value = client
        .get(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let inv = list
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["token"].as_str() == Some(inv_token.as_str()))
        .expect("invite must still be listed");
    assert_eq!(
        inv["use_count"].as_i64().unwrap(),
        1,
        "use_count must be exactly 1 after TOCTOU race"
    );
}

// ---------------------------------------------------------------------------
// revoke_invite
// ---------------------------------------------------------------------------

#[tokio::test]
async fn revoke_invite_admin_gets_204() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "ri_ok").await;
    let group_id = create_group(&client, &base, &token, "RevokeOkGrp").await;
    let inv_token = create_invite_helper(&client, &base, &token, &group_id).await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 204);
}

#[tokio::test]
async fn revoke_invite_accept_afterwards_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "ri_acc_own").await;
    let (joiner_token, _) = register_and_login(&client, &base, "ri_acc_joi").await;
    let group_id = create_group(&client, &base, &owner_token, "RevokeAccGrp").await;
    let inv_token = create_invite_helper(&client, &base, &owner_token, &group_id).await;

    // Revoke the invite.
    client
        .delete(format!("{base}/api/groups/{group_id}/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();

    // Subsequent accept must fail.
    let resp = client
        .post(format!("{base}/api/invites/{inv_token}/accept"))
        .header("Authorization", format!("Bearer {joiner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn revoke_invite_nonexistent_token_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "ri_nil").await;
    let group_id = create_group(&client, &base, &token, "RevokeNilGrp").await;

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/invites/doesnotexist"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn revoke_invite_regular_member_gets_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _) = register_and_login(&client, &base, "ri_mem_own").await;
    let (member_token, member_id) = register_and_login(&client, &base, "ri_mem_mem").await;
    let group_id = create_group(&client, &base, &owner_token, "RevokeForbidGrp").await;
    let inv_token = create_invite_helper(&client, &base, &owner_token, &group_id).await;

    client
        .post(format!("{base}/api/groups/{group_id}/members"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&serde_json::json!({ "user_id": member_id }))
        .send()
        .await
        .unwrap();

    let resp = client
        .delete(format!("{base}/api/groups/{group_id}/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn revoke_invite_no_longer_appears_in_list() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = register_and_login(&client, &base, "ri_list").await;
    let group_id = create_group(&client, &base, &token, "RevokeListGrp").await;
    let inv_token = create_invite_helper(&client, &base, &token, &group_id).await;

    // Revoke.
    client
        .delete(format!("{base}/api/groups/{group_id}/invites/{inv_token}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    // Token must no longer appear in the list.
    let list: Vec<Value> = client
        .get(format!("{base}/api/groups/{group_id}/invites"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(
        !list
            .iter()
            .any(|i| i["token"].as_str() == Some(inv_token.as_str())),
        "revoked invite must not appear in list"
    );
}
