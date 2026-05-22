//! Production-validation regression: when a group has a current key version
//! but the caller has NO per-user envelope at that version (e.g. they joined
//! after the last rotation, or rotation completed without including them),
//! `GET /api/groups/:id/keys/latest` must return 410 Gone with a structured
//! body so the client can surface the "Refresh key" recovery affordance.
//!
//! The previous behaviour fell back to the `group_keys` sentinel row and
//! served `"__envelope__"` as the encrypted_key. The client tried to AES-
//! unwrap that 9-byte ASCII placeholder and failed with
//! `GroupEnvelopeUnwrapException: candidate key has wrong length: 9 bytes`,
//! producing endless `[Could not decrypt...]` placeholders with no signal.

mod common;

use reqwest::Client;
use serde_json::Value;

#[tokio::test]
async fn get_latest_returns_410_when_caller_has_no_envelope_at_latest_version() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, owner_id, _) = common::register_and_login(&client, &base, "gknoeown").await;
    let (member_token, member_id, _) = common::register_and_login(&client, &base, "gknomem").await;

    let group_id = common::create_group(&client, &base, &owner_token, "GKNoEnv").await;
    common::add_member_to_group(&client, &base, &owner_token, &group_id, &member_id).await;

    // Rotate with envelopes for the owner only — simulates the
    // production bug where `performRotation` silently `continue`d past
    // a member with no published identity key.
    let body = serde_json::json!({
        "key_version": 1,
        "envelopes": [
            { "user_id": owner_id, "encrypted_key": "owner-secret" }
        ]
    });
    let resp = client
        .post(format!("{base}/api/groups/{group_id}/keys"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);

    // Owner gets their envelope (happy path).
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["encrypted_key"], "owner-secret");

    // Member has no envelope at v1 — must get 410 Gone, NOT the sentinel.
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {member_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        410,
        "caller with no envelope at the latest version must get 410 Gone, \
         not the `__envelope__` sentinel"
    );
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["code"], "no-envelope-for-user");
    assert_eq!(body["key_version"], 1);
    // Make sure we did NOT leak the sentinel into the response.
    assert!(
        body.get("encrypted_key").is_none(),
        "410 body must not contain the sentinel encrypted_key field"
    );
}

#[tokio::test]
async fn get_latest_still_returns_400_when_group_has_no_key_at_all() {
    // Distinct condition: "no key version exists for this group at all"
    // (pre-encryption groups). Must stay 400 so existing tests + clients
    // that treat 400 as "group is plaintext" keep working — only the
    // "caller missing from current version" sub-case is the new 410.
    let base = common::spawn_server().await;
    let client = Client::new();
    let (owner_token, _owner_id, _) = common::register_and_login(&client, &base, "gknokey").await;

    let group_id = common::create_group(&client, &base, &owner_token, "GKNoKey").await;

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/keys/latest"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        400,
        "no key version at all must remain 400 (legacy contract)"
    );
}
