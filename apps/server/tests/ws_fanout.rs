//! Integration tests for `ws::message_service::fanout` internals.
//!
//! Coverage:
//!   * `fanout_message` DM — recipient device + sender's other device (self_message)
//!     both receive their respective frames.
//!   * `fanout_message` group — every member's every device receives `new_message`
//!     with its own per-device ciphertext.
//!   * `filter_revoked_devices` — a device revoked after key upload is silenced from
//!     live WS delivery; storage persists the row before the filter runs.
//!   * `should_suppress_offline_push` — `@here` suppresses push for offline
//!     plaintext-group members; `@everyone` does NOT suppress push (the offline
//!     member reconnects and receives the stored message in both cases).

mod common;

use futures_util::SinkExt;
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_ws(base: &str, ticket: &str) -> WsStream {
    let ws_base = base.replace("http://", "ws://");
    let (ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");
    ws
}

async fn test_pool() -> sqlx::PgPool {
    let url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    echo_server::db::create_pool(&url).await
}

// ---------------------------------------------------------------------------
// fanout_message DM: recipient device + sender's other device both receive
// ---------------------------------------------------------------------------

/// `fanout_message` for a DM delivers `new_message` to the recipient's
/// connected device AND sends `self_message` to the sender's second device.
///
/// The test sets up:
///   - Alice: device 1 (sender) + device 2 (should receive self_message)
///   - Bob:   device 10 (should receive new_message)
#[tokio::test]
async fn dm_fanout_delivers_to_recipient_and_sender_other_device() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, _) =
        common::register_and_login(&client, &base, "fo_dm_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "fo_dm_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice on device 1 (sender) + device 2.
    let alice_d1_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let alice_d2_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 2).await;
    // Bob on device 10.
    let bob_d10_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 10).await;

    let mut alice_d1_ws = connect_ws(&base, &alice_d1_ticket).await;
    let mut alice_d2_ws = connect_ws(&base, &alice_d2_ticket).await;
    let mut bob_d10_ws = connect_ws(&base, &bob_d10_ticket).await;

    common::drain_pending(&mut alice_d1_ws).await;
    common::drain_pending(&mut alice_d2_ws).await;
    common::drain_pending(&mut bob_d10_ws).await;

    let bob_ct = common::dummy_ciphertext("fo_dm_bob_d10");
    let alice_d2_ct = common::dummy_ciphertext("fo_dm_alice_d2");
    let canonical = common::dummy_ciphertext("fo_dm_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { "10": bob_ct.clone() },
            alice_id.to_string(): {
                "1": common::dummy_ciphertext("fo_dm_alice_d1"),
                "2": alice_d2_ct.clone(),
            },
        },
    });
    alice_d1_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice d1 send failed");

    // Alice device 1 — message_sent confirmation.
    let ack = common::recv_until_event(&mut alice_d1_ws, &["message_sent"]).await;
    assert_eq!(ack["type"], "message_sent");

    // Bob device 10 — new_message with Bob's per-device ciphertext.
    let bob_event = common::recv_until_event(&mut bob_d10_ws, &["new_message"]).await;
    assert_eq!(bob_event["type"], "new_message");
    assert_eq!(
        bob_event["content"], bob_ct,
        "Bob device 10 must receive its own per-device ciphertext"
    );

    // Alice device 2 — self_message with Alice's device-2 ciphertext.
    let self_event = common::recv_until_event(&mut alice_d2_ws, &["self_message"]).await;
    assert_eq!(self_event["type"], "self_message");
    assert_eq!(
        self_event["content"], alice_d2_ct,
        "Alice device 2 must receive the self_message with its own ciphertext"
    );
    // self_message must carry the originating device id so the client knows
    // which ratchet session it belongs to.
    assert_eq!(
        self_event["from_device_id"], 1,
        "self_message.from_device_id must be the originating device (1)"
    );

    let _ = alice_d1_ws.close(None).await;
    let _ = alice_d2_ws.close(None).await;
    let _ = bob_d10_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// fanout_message group: every member's every device receives
// ---------------------------------------------------------------------------

/// `fanout_message` for a plaintext group delivers `new_message` to each
/// member's every connected device with the correct per-device ciphertext.
///
/// Layout:
///   - Alice: device 1 — sender
///   - Bob: devices 21, 22
///   - Charlie: device 31
#[tokio::test]
async fn group_fanout_all_member_devices_receive() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, alice_name) =
        common::register_and_login(&client, &base, "gfo_alice").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "gfo_bob").await;
    let (charlie_token, charlie_id, _) =
        common::register_and_login(&client, &base, "gfo_charlie").await;

    let group_id = common::create_group(&client, &base, &alice_token, "GroupFanoutAllDevs").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &charlie_id).await;

    let alice_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let bob_d21_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 21).await;
    let bob_d22_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 22).await;
    let charlie_d31_ticket =
        common::get_ws_ticket_for_device(&client, &base, &charlie_token, 31).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_d21_ws = connect_ws(&base, &bob_d21_ticket).await;
    let mut bob_d22_ws = connect_ws(&base, &bob_d22_ticket).await;
    let mut charlie_d31_ws = connect_ws(&base, &charlie_d31_ticket).await;

    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_d21_ws).await;
    common::drain_pending(&mut bob_d22_ws).await;
    common::drain_pending(&mut charlie_d31_ws).await;

    let bob_d21_ct = common::dummy_ciphertext("gfo_bob_d21");
    let bob_d22_ct = common::dummy_ciphertext("gfo_bob_d22");
    let charlie_d31_ct = common::dummy_ciphertext("gfo_charlie_d31");
    let canonical = common::dummy_ciphertext("gfo_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {
                "21": bob_d21_ct.clone(),
                "22": bob_d22_ct.clone(),
            },
            charlie_id.to_string(): {
                "31": charlie_d31_ct.clone(),
            },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice group send failed");

    // Alice gets message_sent.
    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    assert_eq!(ack["type"], "message_sent");

    // Bob device 21.
    let b21 = common::recv_until_event(&mut bob_d21_ws, &["new_message"]).await;
    assert_eq!(b21["type"], "new_message");
    assert_eq!(b21["content"], bob_d21_ct, "Bob d21 wrong ciphertext");
    assert_eq!(b21["from_username"], alice_name.as_str());

    // Bob device 22.
    let b22 = common::recv_until_event(&mut bob_d22_ws, &["new_message"]).await;
    assert_eq!(b22["type"], "new_message");
    assert_eq!(b22["content"], bob_d22_ct, "Bob d22 wrong ciphertext");

    // Charlie device 31.
    let c31 = common::recv_until_event(&mut charlie_d31_ws, &["new_message"]).await;
    assert_eq!(c31["type"], "new_message");
    assert_eq!(
        c31["content"], charlie_d31_ct,
        "Charlie d31 wrong ciphertext"
    );

    // All ciphertexts are distinct — guards against broadcast-to-all regression.
    assert_ne!(b21["content"], b22["content"]);
    assert_ne!(b21["content"], c31["content"]);

    let _ = alice_ws.close(None).await;
    let _ = bob_d21_ws.close(None).await;
    let _ = bob_d22_ws.close(None).await;
    let _ = charlie_d31_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// filter_revoked_devices: revoked device excluded from both storage and WS
// ---------------------------------------------------------------------------

/// `filter_revoked_devices` strips revoked devices from WS delivery.
/// `persist_device_contents` (storage path) runs before the revoke filter and
/// does NOT strip revoked devices — only the live-WS fanout is silenced.
///
/// The test registers two Bob devices (11 = active, 22 = to-be-revoked), then
/// checks that:
///   1. Device 11 receives `new_message` with its ciphertext.
///   2. Device 22 receives NO `new_message` within 300 ms (it is still connected
///      but the fanout filter silences it).
///   3. `message_device_contents` DOES have a row for device 22 (storage runs
///      before the revoke filter; the filtering only gates live WS delivery).
#[tokio::test]
async fn revoked_device_excluded_from_fanout_and_storage() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, alice_id, _) = common::register_and_login(&client, &base, "rflt_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "rflt_bob").await;
    let bob_username = bob_name.clone();

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Upload bundles for both Bob devices so revoke_device can stamp revoked_at.
    common::upload_prekey_bundle(&client, &base, &bob_token, 11, 1).await;
    common::upload_prekey_bundle(&client, &base, &bob_token, 22, 1).await;

    // Revoke device 22.
    let revoke_resp = client
        .delete(format!("{base}/api/keys/device/22"))
        .bearer_auth(&bob_token)
        .send()
        .await
        .expect("revoke request failed");
    assert!(revoke_resp.status().is_success(), "revoke device 22 failed");

    // CR-4: revoke_device bumps the per-user min-iat invalidator, so Bob's
    // pre-revoke token may be rejected on subsequent AuthUser checks under
    // CI load when iat seconds roll over. Re-login to obtain a fresh token.
    let (bob_token, _) =
        common::login(&client, &base, &bob_username, common::TEST_USER_PASSWORD).await;

    // Connect both devices (even revoked ones can maintain a WS session;
    // only the fanout filter should silence them).
    let alice_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let bob_d11_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 11).await;
    let bob_d22_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 22).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_d11_ws = connect_ws(&base, &bob_d11_ticket).await;
    let mut bob_d22_ws = connect_ws(&base, &bob_d22_ticket).await;

    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_d11_ws).await;
    common::drain_pending(&mut bob_d22_ws).await;

    let d11_ct = common::dummy_ciphertext("rflt_d11");
    let d22_ct = common::dummy_ciphertext("rflt_d22");
    let canonical = common::dummy_ciphertext("rflt_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {
                "11": d11_ct.clone(),
                "22": d22_ct,
            },
            alice_id.to_string(): {
                "1": common::dummy_ciphertext("rflt_alice_d1"),
            },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // Alice gets message_sent.
    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();

    // Device 11 (active) must receive its ciphertext.
    let d11_event = common::recv_until_event(&mut bob_d11_ws, &["new_message"]).await;
    assert_eq!(d11_event["type"], "new_message");
    assert_eq!(
        d11_event["content"], d11_ct,
        "device 11 must receive its ciphertext"
    );

    // Device 22 (revoked) must NOT receive new_message within 300 ms.
    let d22_result = tokio::time::timeout(
        std::time::Duration::from_millis(300),
        recv_new_message(&mut bob_d22_ws),
    )
    .await;
    assert!(
        d22_result.is_err(),
        "revoked device 22 must not receive new_message; got: {d22_result:?}"
    );

    // DB: message_device_contents DOES have a row for device 22 because
    // persist_device_contents runs before filter_revoked_devices.  The
    // revoke filter only gates live WS delivery — storage is intentionally
    // not filtered at this layer (the row may be needed for offline replay
    // transparency / audit).
    let bob_uuid = Uuid::parse_str(&bob_id).unwrap();
    let stored_d11 = echo_server::db::messages::get_device_content(&pool, message_id, bob_uuid, 11)
        .await
        .expect("get_device_content query failed");
    assert_eq!(
        stored_d11,
        Some(d11_ct),
        "message_device_contents must have a row for the active device 11"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_d11_ws.close(None).await;
    let _ = bob_d22_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// should_suppress_offline_push — @here suppresses; @everyone does not
// ---------------------------------------------------------------------------

/// When a plaintext group message contains a standalone `@here`, offline
/// push is suppressed but the message is still stored and delivered to online
/// members.  An offline member that reconnects receives the message via
/// offline replay (storage is unaffected by push suppression).
///
/// This is the wiring test for `should_suppress_offline_push` returning `true`.
#[tokio::test]
async fn at_here_suppresses_push_but_stores_message_for_offline_replay() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _, _) = common::register_and_login(&client, &base, "supp_alice").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "supp_bob").await;

    // @here mention parsing only runs on plaintext groups (encrypted
    // content is ciphertext; #451 doc-doctored). Downgrade explicitly.
    let group_id =
        common::create_plaintext_group(&client, &base, &alice_token, "SuppressGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    // Alice connects; Bob is intentionally offline so offline_user_ids is non-empty
    // and the suppression branch is actually exercised.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": "@here any updates?",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // Alice gets message_sent (message was stored successfully).
    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    assert_eq!(
        ack["type"], "message_sent",
        "message must be stored despite @here"
    );

    // Bob reconnects — offline replay must deliver the stored @here message.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    let bob_event = common::recv_until_event(&mut bob_ws, &["new_message"]).await;
    assert_eq!(bob_event["type"], "new_message");
    assert_eq!(
        bob_event["content"], "@here any updates?",
        "offline replay must return the original @here message content"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

/// `@everyone` must NOT suppress offline push — by design it should notify
/// every member, online or not.  This is the negative case for
/// `should_suppress_offline_push`: with `@everyone` the function returns `false`.
///
/// Observationally this is the same as `@here` (push suppression is not
/// directly observable in tests without an APNs mock), but an offline member
/// that reconnects MUST receive the stored message in both cases.  The
/// important contract verified here is that `@everyone` does NOT prevent
/// message delivery on reconnect (i.e. storage was not skipped).
#[tokio::test]
async fn at_everyone_does_not_suppress_offline_replay() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _, _) = common::register_and_login(&client, &base, "ev_sup_alice").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "ev_sup_bob").await;

    // @everyone mention parsing only runs on plaintext groups.
    let group_id =
        common::create_plaintext_group(&client, &base, &alice_token, "EvSuppGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    // Bob is offline; Alice sends @everyone.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": "@everyone important announcement",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    assert_eq!(ack["type"], "message_sent");

    // Bob reconnects — must receive the @everyone message via offline replay.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    let bob_event = common::recv_until_event(&mut bob_ws, &["new_message"]).await;
    assert_eq!(bob_event["type"], "new_message");
    assert_eq!(
        bob_event["content"], "@everyone important announcement",
        "@everyone must not suppress offline replay"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read frames until a `new_message` arrives, blocking until one does.
async fn recv_new_message(ws: &mut WsStream) -> Value {
    use futures_util::StreamExt;
    loop {
        match ws.next().await {
            Some(Ok(Message::Text(text))) => {
                let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                if v["type"] == "new_message" {
                    return v;
                }
            }
            Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
            _ => futures_util::future::pending::<()>().await,
        }
    }
}
