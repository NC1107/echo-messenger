//! Integration tests for PreKey bundle upload, fetch, and device management.

mod common;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use ed25519_dalek::{Signer, SigningKey};
use reqwest::Client;
use serde_json::Value;

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

#[tokio::test]
async fn upload_bundle_returns_201() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyup").await;

    common::upload_prekey_bundle(&client, &base, &token, 0, 3).await;
}

#[tokio::test]
async fn upload_bundle_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let body = serde_json::json!({
        "identity_key": BASE64.encode([0u8; 32]),
        "signed_prekey": BASE64.encode([0u8; 32]),
        "signed_prekey_signature": BASE64.encode([0u8; 64]),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode([0u8; 32]),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn upload_bundle_bad_signature_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keybadsig").await;

    // Generate two different signing keys: one to produce the signature,
    // another for the `signing_key` field. The server should reject the
    // mismatch.
    let signing_key_a = SigningKey::from_bytes(&rand::random::<[u8; 32]>());
    let signing_key_b = SigningKey::from_bytes(&rand::random::<[u8; 32]>());
    let signed_prekey = rand::random::<[u8; 32]>().to_vec();

    // Sign with key A but upload key B's public key
    let signature = signing_key_a.sign(&signed_prekey);

    let identity_key = rand::random::<[u8; 32]>().to_vec();

    let body = serde_json::json!({
        "identity_key": BASE64.encode(&identity_key),
        "signed_prekey": BASE64.encode(&signed_prekey),
        "signed_prekey_signature": BASE64.encode(signature.to_bytes()),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode(signing_key_b.verifying_key().to_bytes()),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_bundle_invalid_base64_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyb64").await;

    let body = serde_json::json!({
        "identity_key": "not!valid!base64!!!",
        "signed_prekey": BASE64.encode([0u8; 32]),
        "signed_prekey_signature": BASE64.encode([0u8; 64]),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode([0u8; 32]),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_bundle_returns_uploaded_data() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (token_a, uid_a, _) = common::register_and_login(&client, &base, "keyfetcha").await;
    let (token_b, _uid_b, _) = common::register_and_login(&client, &base, "keyfetchb").await;

    let bundle = common::upload_prekey_bundle(&client, &base, &token_a, 0, 1).await;

    let resp = client
        .get(format!("{base}/api/keys/bundle/{uid_a}"))
        .header("Authorization", format!("Bearer {token_b}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();

    assert_eq!(body["identity_key"], BASE64.encode(&bundle.identity_key));
    assert_eq!(body["signed_prekey"], BASE64.encode(&bundle.signed_prekey));
    assert_eq!(body["signed_prekey_id"], bundle.signed_prekey_id);

    // Verify signing_key is present
    assert_eq!(
        body["signing_key"].as_str().unwrap(),
        BASE64.encode(&bundle.signing_key_bytes)
    );
}

#[tokio::test]
async fn get_bundle_no_keys_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (_token_a, uid_a, _) = common::register_and_login(&client, &base, "keynobnd").await;
    let (token_b, _uid_b, _) = common::register_and_login(&client, &base, "keynobnd2").await;

    let resp = client
        .get(format!("{base}/api/keys/bundle/{uid_a}"))
        .header("Authorization", format!("Bearer {token_b}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn get_bundle_consumes_one_time_prekey() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (token_a, uid_a, _) = common::register_and_login(&client, &base, "keyotpa").await;
    let (token_b, _uid_b, _) = common::register_and_login(&client, &base, "keyotpb").await;

    common::upload_prekey_bundle(&client, &base, &token_a, 0, 3).await;

    // Fetch 3 times -- each should return a unique OTP
    let mut seen_key_ids = Vec::new();
    for _ in 0..3 {
        let resp = client
            .get(format!("{base}/api/keys/bundle/{uid_a}"))
            .header("Authorization", format!("Bearer {token_b}"))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status().as_u16(), 200);
        let body: Value = resp.json().await.unwrap();

        let otp = &body["one_time_prekey"];
        assert!(
            otp.is_object(),
            "fetch {}: should return an OTP",
            seen_key_ids.len() + 1
        );
        let kid = otp["key_id"].as_i64().unwrap();
        assert!(
            !seen_key_ids.contains(&kid),
            "OTP key_id {kid} already consumed"
        );
        seen_key_ids.push(kid);
    }

    // 4th fetch: OTPs exhausted
    let resp = client
        .get(format!("{base}/api/keys/bundle/{uid_a}"))
        .header("Authorization", format!("Bearer {token_b}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["one_time_prekey"].is_null(),
        "4th fetch should have no OTP left"
    );
}

// ---------------------------------------------------------------------------
// OTP count
// ---------------------------------------------------------------------------

#[tokio::test]
async fn otp_count_reflects_remaining() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (token_a, uid_a, _) = common::register_and_login(&client, &base, "keyotp5a").await;
    let (token_b, _uid_b, _) = common::register_and_login(&client, &base, "keyotp5b").await;

    common::upload_prekey_bundle(&client, &base, &token_a, 0, 5).await;

    // Should be 5 initially
    let resp = client
        .get(format!("{base}/api/keys/otp-count?device_id=0"))
        .header("Authorization", format!("Bearer {token_a}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["count"], 5);

    // Consume 1 by fetching
    client
        .get(format!("{base}/api/keys/bundle/{uid_a}"))
        .header("Authorization", format!("Bearer {token_b}"))
        .send()
        .await
        .unwrap();

    // Should be 4
    let resp = client
        .get(format!("{base}/api/keys/otp-count?device_id=0"))
        .header("Authorization", format!("Bearer {token_a}"))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["count"], 4);
}

// ---------------------------------------------------------------------------
// Key length validation (X25519 keys must be exactly 32 bytes)
// ---------------------------------------------------------------------------

/// Build a valid signing key + signature pair over `signed_prekey_bytes` so we
/// can isolate identity_key / OTP length failures without the signature check
/// interfering.
fn make_valid_signing_pair(signed_prekey_bytes: &[u8]) -> (SigningKey, Vec<u8>, Vec<u8>) {
    let sk = SigningKey::from_bytes(&rand::random::<[u8; 32]>());
    let sig = sk.sign(signed_prekey_bytes).to_bytes().to_vec();
    let vk = sk.verifying_key().to_bytes().to_vec();
    (sk, vk, sig)
}

#[tokio::test]
async fn upload_bundle_short_identity_key_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyshortid").await;

    let signed_prekey = rand::random::<[u8; 32]>();
    let (_sk, vk, sig) = make_valid_signing_pair(&signed_prekey);

    let body = serde_json::json!({
        "identity_key": BASE64.encode([0u8; 16]),  // 16 bytes -- too short
        "signed_prekey": BASE64.encode(signed_prekey),
        "signed_prekey_signature": BASE64.encode(&sig),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode(&vk),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_bundle_oversized_identity_key_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyoverId").await;

    let signed_prekey = rand::random::<[u8; 32]>();
    let (_sk, vk, sig) = make_valid_signing_pair(&signed_prekey);

    let body = serde_json::json!({
        "identity_key": BASE64.encode([0u8; 64]),  // 64 bytes -- too long
        "signed_prekey": BASE64.encode(signed_prekey),
        "signed_prekey_signature": BASE64.encode(&sig),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode(&vk),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_bundle_short_signed_prekey_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyshortspk").await;

    // Sign the short prekey so the only failing check is the length guard.
    let short_spk = [0u8; 16];
    let (_sk, vk, sig) = make_valid_signing_pair(&short_spk);

    let body = serde_json::json!({
        "identity_key": BASE64.encode([0u8; 32]),
        "signed_prekey": BASE64.encode(short_spk),  // 16 bytes -- too short
        "signed_prekey_signature": BASE64.encode(&sig),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode(&vk),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_bundle_oversized_signed_prekey_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyoverspk").await;

    // Sign the oversized prekey so the only failing check is the length guard.
    let big_spk = [0u8; 64];
    let (_sk, vk, sig) = make_valid_signing_pair(&big_spk);

    let body = serde_json::json!({
        "identity_key": BASE64.encode([0u8; 32]),
        "signed_prekey": BASE64.encode(big_spk),  // 64 bytes -- too long
        "signed_prekey_signature": BASE64.encode(&sig),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode(&vk),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_bundle_short_otp_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyshortotp").await;

    let signed_prekey = rand::random::<[u8; 32]>();
    let (_sk, vk, sig) = make_valid_signing_pair(&signed_prekey);

    let body = serde_json::json!({
        "identity_key": BASE64.encode([0u8; 32]),
        "signed_prekey": BASE64.encode(signed_prekey),
        "signed_prekey_signature": BASE64.encode(&sig),
        "signed_prekey_id": 1,
        "one_time_prekeys": [{"key_id": 1, "public_key": BASE64.encode([0u8; 16])}],  // 16 bytes
        "device_id": 0,
        "signing_key": BASE64.encode(&vk),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn upload_bundle_oversized_otp_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyoverotp").await;

    let signed_prekey = rand::random::<[u8; 32]>();
    let (_sk, vk, sig) = make_valid_signing_pair(&signed_prekey);

    let body = serde_json::json!({
        "identity_key": BASE64.encode([0u8; 32]),
        "signed_prekey": BASE64.encode(signed_prekey),
        "signed_prekey_signature": BASE64.encode(&sig),
        "signed_prekey_id": 1,
        "one_time_prekeys": [{"key_id": 1, "public_key": BASE64.encode([0u8; 64])}],  // 64 bytes
        "device_id": 0,
        "signing_key": BASE64.encode(&vk),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Identity key binding
// ---------------------------------------------------------------------------

#[tokio::test]
async fn identity_key_mismatch_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyid409").await;

    // First upload -- binds identity key
    common::upload_prekey_bundle(&client, &base, &token, 0, 0).await;

    // Second upload with DIFFERENT identity key
    let signing_key = SigningKey::from_bytes(&rand::random::<[u8; 32]>());
    let signing_key_pub = signing_key.verifying_key().to_bytes();

    let new_identity_key = rand::random::<[u8; 32]>().to_vec();
    let signed_prekey = rand::random::<[u8; 32]>().to_vec();
    let signature = signing_key.sign(&signed_prekey);

    let body = serde_json::json!({
        "identity_key": BASE64.encode(&new_identity_key),
        "signed_prekey": BASE64.encode(&signed_prekey),
        "signed_prekey_signature": BASE64.encode(signature.to_bytes()),
        "signed_prekey_id": 1,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode(signing_key_pub),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 409);
}

#[tokio::test]
async fn identity_key_same_allows_reupload() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyreup").await;

    let bundle = common::upload_prekey_bundle(&client, &base, &token, 0, 0).await;

    // Re-upload with SAME identity key but fresh signed prekey
    let signed_prekey = rand::random::<[u8; 32]>().to_vec();
    let signature = bundle.signing_key.sign(&signed_prekey);

    let body = serde_json::json!({
        "identity_key": BASE64.encode(&bundle.identity_key),
        "signed_prekey": BASE64.encode(&signed_prekey),
        "signed_prekey_signature": BASE64.encode(signature.to_bytes()),
        "signed_prekey_id": 2,
        "one_time_prekeys": [],
        "device_id": 0,
        "signing_key": BASE64.encode(&bundle.signing_key_bytes),
    });

    let resp = client
        .post(format!("{base}/api/keys/upload"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
}

// ---------------------------------------------------------------------------
// Multi-device
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_devices_returns_device_ids() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, uid, _) = common::register_and_login(&client, &base, "keydev").await;

    let bundle0 = common::upload_prekey_bundle(&client, &base, &token, 0, 0).await;
    common::upload_additional_device(&client, &base, &token, &bundle0, 1).await;

    // Fetch device list
    let (token_other, _, _) = common::register_and_login(&client, &base, "keydevother").await;
    let resp = client
        .get(format!("{base}/api/keys/devices/{uid}"))
        .header("Authorization", format!("Bearer {token_other}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let devices = body["devices"].as_array().expect("devices array present");
    let device_ids: Vec<i64> = devices
        .iter()
        .map(|d| d["device_id"].as_i64().unwrap())
        .collect();
    assert!(device_ids.contains(&0), "should list device 0");
    assert!(device_ids.contains(&1), "should list device 1");
    // Each entry must at minimum expose a device_id; platform and last_seen
    // are optional and only populated once the client uploads metadata or the
    // device connects over WebSocket.
    for d in devices {
        assert!(d.get("device_id").is_some(), "missing device_id field");
    }
}

#[tokio::test]
async fn get_all_bundles_returns_all_devices() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, uid, _) = common::register_and_login(&client, &base, "keyallbnd").await;

    let bundle0 = common::upload_prekey_bundle(&client, &base, &token, 0, 1).await;
    common::upload_additional_device(&client, &base, &token, &bundle0, 1).await;

    let (token_other, _, _) = common::register_and_login(&client, &base, "keyallbndoth").await;
    let resp = client
        .get(format!("{base}/api/keys/bundles/{uid}"))
        .header("Authorization", format!("Bearer {token_other}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let bundles = body["bundles"].as_array().unwrap();
    assert_eq!(bundles.len(), 2, "should have bundles for 2 devices");

    let dev_ids: Vec<i64> = bundles
        .iter()
        .map(|b| b["device_id"].as_i64().unwrap())
        .collect();
    assert!(dev_ids.contains(&0));
    assert!(dev_ids.contains(&1));
}

#[tokio::test]
async fn revoke_device_removes_keys() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, uid, _) = common::register_and_login(&client, &base, "keyrevoke").await;

    let bundle0 = common::upload_prekey_bundle(&client, &base, &token, 0, 0).await;
    common::upload_additional_device(&client, &base, &token, &bundle0, 1).await;

    // Revoke device 1
    let resp = client
        .delete(format!("{base}/api/keys/device/1"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 204);

    // Fetch device 1 bundle should fail
    let (token_other, _, _) = common::register_and_login(&client, &base, "keyrevoth").await;
    let resp = client
        .get(format!("{base}/api/keys/bundle/{uid}/1"))
        .header("Authorization", format!("Bearer {token_other}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn revoke_other_devices_without_auth_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/keys/devices/revoke-others"))
        .json(&serde_json::json!({ "current_device_id": 0 }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn revoke_other_devices_with_unknown_current_id_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _uid, _) = common::register_and_login(&client, &base, "keyrevunknown").await;

    // Upload exactly one device (device 0).
    common::upload_prekey_bundle(&client, &base, &token, 0, 0).await;

    // Pass a current_device_id that isn't registered.
    let resp = client
        .post(format!("{base}/api/keys/devices/revoke-others"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "current_device_id": -1 }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn revoke_other_devices_with_single_device_returns_zero() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, uid, _) = common::register_and_login(&client, &base, "keyrevsingle").await;

    // Upload exactly one device (device 0).
    common::upload_prekey_bundle(&client, &base, &token, 0, 0).await;

    let resp = client
        .post(format!("{base}/api/keys/devices/revoke-others"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "current_device_id": 0 }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["revoked"].as_i64().unwrap(), 0, "nothing to revoke");

    // Device 0 must still be in the device list.
    let (token_other, _, _) = common::register_and_login(&client, &base, "keyrevsingleob").await;
    let resp = client
        .get(format!("{base}/api/keys/devices/{uid}"))
        .header("Authorization", format!("Bearer {token_other}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let device_ids: Vec<i64> = body["devices"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["device_id"].as_i64().unwrap())
        .collect();
    assert_eq!(device_ids, vec![0], "device 0 must still exist");
}

#[tokio::test]
async fn revoke_other_devices_keeps_current_drops_rest() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, uid, _) = common::register_and_login(&client, &base, "keyrevothers").await;

    // Upload three devices (0, 1, 2)
    let bundle0 = common::upload_prekey_bundle(&client, &base, &token, 0, 0).await;
    common::upload_additional_device(&client, &base, &token, &bundle0, 1).await;
    common::upload_additional_device(&client, &base, &token, &bundle0, 2).await;

    // Keep device 0, revoke the rest.
    let resp = client
        .post(format!("{base}/api/keys/devices/revoke-others"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "current_device_id": 0 }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["revoked"].as_i64().unwrap(), 2, "should revoke 2");

    // Only device 0 should remain in the device list.
    let (token_other, _, _) = common::register_and_login(&client, &base, "keyrevothersobs").await;
    let resp = client
        .get(format!("{base}/api/keys/devices/{uid}"))
        .header("Authorization", format!("Bearer {token_other}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let device_ids: Vec<i64> = body["devices"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["device_id"].as_i64().unwrap())
        .collect();
    assert_eq!(device_ids, vec![0], "only device 0 should remain");
}
