//! Integration test for WebSocket messaging between two users.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

/// Full end-to-end test: register two users, make them contacts, connect via
/// WebSocket, send a message from Alice to Bob, and verify both sides receive
/// the expected server events.
#[tokio::test]
async fn alice_sends_bob_receives() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, alice_name) =
        common::register_and_login(&client, &base, "alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // DMs are auto-encrypted, so the ciphertext-shape gate (#591) requires a
    // wire-shaped canonical content and per-recipient device ciphertexts.
    let canonical = common::dummy_ciphertext("alice_to_bob_canonical");
    let bob_ct = common::dummy_ciphertext("alice_to_bob_d0");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical.clone(),
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct.clone() },
            alice_id.to_string(): { "0": canonical.clone() },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // -- Alice should receive `message_sent` ----------------------------------
    let alice_event = read_text_skipping_presence(&mut alice_ws).await;
    let alice_msg: Value = serde_json::from_str(&alice_event).expect("Alice JSON parse failed");
    assert_eq!(
        alice_msg["type"], "message_sent",
        "Alice should get message_sent"
    );

    // -- Bob should receive `new_message` -------------------------------------
    let bob_event = read_text_skipping_presence(&mut bob_ws).await;
    let bob_msg: Value = serde_json::from_str(&bob_event).expect("Bob JSON parse failed");
    assert_eq!(bob_msg["type"], "new_message", "Bob should get new_message");
    assert_eq!(
        bob_msg["content"], bob_ct,
        "Message content should be Bob's per-device ciphertext"
    );
    assert_eq!(
        bob_msg["from_username"],
        alice_name.as_str(),
        "from_username should be Alice"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Typing indicator
// ---------------------------------------------------------------------------

#[tokio::test]
async fn typing_indicator_broadcast() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, alice_name) =
        common::register_and_login(&client, &base, "typalice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "typbob").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // Alice sends typing indicator
    let typing_msg = serde_json::json!({
        "type": "typing",
        "conversation_id": conv_id,
    });
    alice_ws
        .send(Message::Text(typing_msg.to_string().into()))
        .await
        .expect("Alice typing send failed");

    // Bob should receive typing event
    let bob_event = read_text_skipping_chatter(&mut bob_ws).await;
    let event: Value = serde_json::from_str(&bob_event).expect("Bob typing JSON parse failed");
    assert_eq!(event["type"], "typing", "Bob should get typing event");
    assert_eq!(event["conversation_id"], conv_id);
    assert_eq!(event["from_username"], alice_name.as_str());

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Read receipt
// ---------------------------------------------------------------------------

#[tokio::test]
async fn read_receipt_broadcast() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "rralice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "rrbob").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // Alice sends a message to create some content to read. DMs are
    // auto-encrypted so the payload must be wire-shaped (#591).
    let canonical = common::dummy_ciphertext("rr_canonical");
    let bob_ct = common::dummy_ciphertext("rr_bob");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": conv_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // Drain the message_sent and new_message events
    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // Bob sends read receipt
    let rr_msg = serde_json::json!({
        "type": "read_receipt",
        "conversation_id": conv_id,
    });
    bob_ws
        .send(Message::Text(rr_msg.to_string().into()))
        .await
        .expect("Bob read_receipt send failed");

    // Alice should receive read_receipt
    let alice_event = read_text_skipping_chatter(&mut alice_ws).await;
    let event: Value =
        serde_json::from_str(&alice_event).expect("Alice read_receipt JSON parse failed");
    assert_eq!(
        event["type"], "read_receipt",
        "Alice should get read_receipt"
    );
    assert_eq!(event["conversation_id"], conv_id);
    assert_eq!(event["user_id"], bob_id.as_str());

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Key reset
// ---------------------------------------------------------------------------

#[tokio::test]
async fn key_reset_broadcast() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, alice_name) =
        common::register_and_login(&client, &base, "kralice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "krbob").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // Alice sends key_reset
    let kr_msg = serde_json::json!({
        "type": "key_reset",
        "conversation_id": conv_id,
    });
    alice_ws
        .send(Message::Text(kr_msg.to_string().into()))
        .await
        .expect("Alice key_reset send failed");

    // Bob should receive key_reset
    let bob_event = read_text_skipping_chatter(&mut bob_ws).await;
    let event: Value = serde_json::from_str(&bob_event).expect("Bob key_reset JSON parse failed");
    assert_eq!(event["type"], "key_reset", "Bob should get key_reset");
    assert_eq!(event["conversation_id"], conv_id);
    assert_eq!(event["from_user_id"], alice_id.as_str());
    assert_eq!(event["from_username"], alice_name.as_str());

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Group message fan-out
// ---------------------------------------------------------------------------

#[tokio::test]
async fn group_message_fanout() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, alice_name) =
        common::register_and_login(&client, &base, "gfalice").await;
    let (bob_token, bob_id, _bob_name) = common::register_and_login(&client, &base, "gfbob").await;
    let (charlie_token, charlie_id, _charlie_name) =
        common::register_and_login(&client, &base, "gfcharlie").await;

    let group_id = common::create_group(&client, &base, &alice_token, "FanoutGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &charlie_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let charlie_ticket = common::get_ws_ticket(&client, &base, &charlie_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    let mut charlie_ws = connect_ws(&base, &charlie_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;
    drain_pending(&mut charlie_ws).await;

    // Alice sends a message to the group
    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": "hello group",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice group send failed");

    // Alice should get message_sent
    let alice_event = read_text_with_timeout(&mut alice_ws).await;
    let alice_msg: Value = serde_json::from_str(&alice_event).unwrap();
    assert_eq!(alice_msg["type"], "message_sent");

    // Bob should get new_message
    let bob_event = read_text_with_timeout(&mut bob_ws).await;
    let bob_msg: Value = serde_json::from_str(&bob_event).unwrap();
    assert_eq!(bob_msg["type"], "new_message");
    assert_eq!(bob_msg["content"], "hello group");
    assert_eq!(bob_msg["from_username"], alice_name.as_str());
    assert_eq!(bob_msg["conversation_id"], group_id.as_str());

    // Charlie should get new_message
    let charlie_event = read_text_with_timeout(&mut charlie_ws).await;
    let charlie_msg: Value = serde_json::from_str(&charlie_event).unwrap();
    assert_eq!(charlie_msg["type"], "new_message");
    assert_eq!(charlie_msg["content"], "hello group");
    assert_eq!(charlie_msg["conversation_id"], group_id.as_str());

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
    let _ = charlie_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

#[tokio::test]
async fn invalid_json_returns_error() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (token, _uid, _) = common::register_and_login(&client, &base, "wsinvalid").await;
    let ticket = common::get_ws_ticket(&client, &base, &token).await;

    let mut ws = connect_ws(&base, &ticket).await;

    drain_pending(&mut ws).await;

    // Send invalid JSON
    ws.send(Message::Text("not valid json {{{".into()))
        .await
        .expect("send failed");

    let event = read_text_with_timeout(&mut ws).await;
    let msg: Value = serde_json::from_str(&event).expect("error JSON parse failed");
    assert_eq!(msg["type"], "error", "should get error event");

    let _ = ws.close(None).await;
}

#[tokio::test]
async fn message_to_noncontact_returns_error() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "ncalice").await;
    let (_eve_token, eve_id, _) = common::register_and_login(&client, &base, "nceve").await;

    // Alice and Eve are NOT contacts

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    // Alice tries to message Eve (not a contact)
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": eve_id,
        "content": "hey stranger",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let event = read_text_with_timeout(&mut alice_ws).await;
    let msg: Value = serde_json::from_str(&event).expect("error JSON parse failed");
    assert_eq!(msg["type"], "error", "should get error for non-contact");
    assert!(
        msg["message"]
            .as_str()
            .unwrap_or("")
            .contains("Not a contact"),
        "error message should mention 'Not a contact'"
    );

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Offline delivery with per-device ciphertext
// ---------------------------------------------------------------------------

/// When a recipient device reconnects and no per-device ciphertext row exists
/// for it, the server must NOT serve the canonical (sender-side) ciphertext --
/// that ciphertext is bound to a different device's Double Ratchet session and
/// would corrupt this device's state.  Instead the offline replay emits an
/// `undecryptable: true` placeholder so the client surfaces "Message
/// unavailable on this device" rather than silently failing to decrypt (#557
/// Bug 2).
#[tokio::test]
async fn offline_delivery_marks_unknown_device_undecryptable() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "odalice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "odbob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice connects, Bob is offline (never connects before the message).
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    // Bob has device_id=42 in this simulation; the test WS path uses device_id=0
    // (the default when no key bundle is registered).
    let bob_device_id: i32 = 42;
    let canonical_ct = common::dummy_ciphertext("od_canonical");
    let device_ct = common::dummy_ciphertext("od_bob_d42");

    // Alice sends a message while Bob is offline, including per-device content.
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical_ct.clone(),
        "recipient_device_contents": {
            bob_id.to_string(): {
                bob_device_id.to_string(): device_ct,
            },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // Alice receives message_sent confirmation.
    let alice_event = read_text_with_timeout(&mut alice_ws).await;
    let alice_msg: Value = serde_json::from_str(&alice_event).expect("Alice JSON parse failed");
    assert_eq!(
        alice_msg["type"], "message_sent",
        "Alice should get message_sent"
    );

    // Bob comes online via the test harness, which assigns device_id = 0 (no
    // key bundle registered).  Per-device row is keyed at device_id = 42, so
    // there is no row for device 0.  Pre-#557 the server would have served
    // `canonical_ct` here -- now it must emit an undecryptable placeholder.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    // Skip the presence_list snapshot that arrives first on connect (#436).
    let bob_msg = common::recv_until_event(&mut bob_ws, &["new_message"]).await;
    assert_eq!(bob_msg["type"], "new_message", "Bob should get new_message");
    assert_eq!(
        bob_msg["undecryptable"], true,
        "Bob (device 0, no per-device row) should get undecryptable=true, not canonical ct"
    );
    assert_ne!(
        bob_msg["content"], canonical_ct,
        "must NOT serve foreign-device ciphertext as canonical content"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

/// Verify that when the sender stores a device-specific ciphertext for the
/// recipient's exact device_id, the offline delivery path returns that
/// ciphertext and not the canonical fallback.
///
/// This test exercises the DB layer directly (store + get) to confirm that
/// `store_device_contents` and `get_device_content` work correctly together
/// before the WS layer wires them up.
#[tokio::test]
async fn device_content_db_roundtrip() {
    // spawn_server runs migrations (via OnceCell) and gives us the DB URL via env.
    let base = common::spawn_server().await;
    let client = Client::new();

    // Open a separate pool for direct DB assertions using the same URL.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "dbrtalice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "dbrtbob").await;
    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice sends a message that stores a device-specific ciphertext.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    drain_pending(&mut alice_ws).await;

    // Both alice and bob use device_id=1 — this is the exact collision case
    // that the recipient-scoped storage fix (#522) must resolve.
    let device_id: i32 = 1;
    let bob_device_ct = common::dummy_ciphertext("dbrt_bob_d1");
    let alice_device_ct = common::dummy_ciphertext("dbrt_alice_d1");
    let canonical = common::dummy_ciphertext("dbrt_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { device_id.to_string(): bob_device_ct.clone() },
            alice_id.to_string(): { device_id.to_string(): alice_device_ct.clone() },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .unwrap();

    let raw = read_text_with_timeout(&mut alice_ws).await;
    let ack: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(ack["type"], "message_sent", "send failed: {raw}");
    let message_id = uuid::Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();

    let bob_uuid = uuid::Uuid::parse_str(&bob_id).unwrap();
    let alice_uuid = uuid::Uuid::parse_str(&alice_id).unwrap();

    // Both rows must be present — the legacy schema would have dropped one of
    // them via ON CONFLICT (message_id, device_id) DO NOTHING.
    let bob_stored =
        echo_server::db::messages::get_device_content(&pool, message_id, bob_uuid, device_id)
            .await
            .expect("db query failed");
    assert_eq!(
        bob_stored,
        Some(bob_device_ct.clone()),
        "Bob's device-1 ciphertext must be stored"
    );

    let alice_stored =
        echo_server::db::messages::get_device_content(&pool, message_id, alice_uuid, device_id)
            .await
            .expect("db query failed");
    assert_eq!(
        alice_stored,
        Some(alice_device_ct.clone()),
        "Alice's device-1 ciphertext must coexist with Bob's despite same device_id"
    );

    // Unknown user/device should return None.
    let missing = echo_server::db::messages::get_device_content(&pool, message_id, bob_uuid, 999)
        .await
        .expect("db query failed");
    assert_eq!(missing, None, "unknown device should return None");

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Multi-device fanout regression (#557)
// ---------------------------------------------------------------------------

/// Bug #557 — when a recipient is connected on multiple devices simultaneously
/// the fanout MUST hand each device its own per-device ciphertext.
/// The pre-fix code used `Iterator::any` which short-circuited after the first
/// successful send, so device #2 silently never received the message and that
/// device's ratchet desynchronized.
#[tokio::test]
async fn test_dm_fanout_delivers_to_all_recipient_devices() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "fanout_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "fanout_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice connects on her primary device.
    let alice_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    // Bob connects on TWO devices using the same access token but distinct
    // device_id values bound to separate WS tickets. This mirrors a user with
    // both desktop and mobile online.
    let bob_d1_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 11).await;
    let bob_d2_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 22).await;
    let mut bob_d1_ws = connect_ws(&base, &bob_d1_ticket).await;
    let mut bob_d2_ws = connect_ws(&base, &bob_d2_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_d1_ws).await;
    drain_pending(&mut bob_d2_ws).await;

    let bob_d1_ct = common::dummy_ciphertext("557_bob_d11");
    let bob_d2_ct = common::dummy_ciphertext("557_bob_d22");
    let canonical = common::dummy_ciphertext("557_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {
                "11": bob_d1_ct.clone(),
                "22": bob_d2_ct.clone(),
            },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // Alice gets her message_sent ack (skip presence noise).
    let ack_text = read_text_skipping_presence(&mut alice_ws).await;
    let ack: Value = serde_json::from_str(&ack_text).unwrap();
    assert_eq!(ack["type"], "message_sent");

    // Both Bob devices must receive `new_message`, each with its own
    // ciphertext.  Pre-fix this test would deadlock or fail on device #2.
    let d1_text = read_text_skipping_presence(&mut bob_d1_ws).await;
    let d1: Value = serde_json::from_str(&d1_text).unwrap();
    assert_eq!(d1["type"], "new_message", "device 1 should get new_message");
    assert_eq!(
        d1["content"], bob_d1_ct,
        "device 1 must receive its own ciphertext"
    );

    let d2_text = read_text_skipping_presence(&mut bob_d2_ws).await;
    let d2: Value = serde_json::from_str(&d2_text).unwrap();
    assert_eq!(d2["type"], "new_message", "device 2 should get new_message");
    assert_eq!(
        d2["content"], bob_d2_ct,
        "device 2 must receive its own ciphertext"
    );

    // Distinct ciphertexts per device — guards against any future regression
    // that would broadcast a single per-recipient frame to multiple devices.
    assert_ne!(d1["content"], d2["content"]);

    let _ = alice_ws.close(None).await;
    let _ = bob_d1_ws.close(None).await;
    let _ = bob_d2_ws.close(None).await;
}

// Group × multi-device fanout regression (#557 follow-up)
// ---------------------------------------------------------------------------

/// `deliver_to_member` is called for every conversation member.  A regression
/// that re-introduced short-circuiting only in the group-fanout branch (e.g.
/// via `filter`/`any` over members) would skip later members entirely.  This
/// test uses a 3-user group where Bob and Charlie each connect on two devices
/// and asserts that every device socket receives its own distinct ciphertext.
#[tokio::test]
async fn test_group_fanout_delivers_to_all_devices_of_all_members() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "gfmd_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "gfmd_bob").await;
    let (charlie_token, charlie_id, _charlie_name) =
        common::register_and_login(&client, &base, "gfmd_charlie").await;

    let group_id = common::create_group(&client, &base, &alice_token, "MultiDevFanoutGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &charlie_id).await;

    // Alice connects on her primary device (sender).
    let alice_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    // Bob connects on TWO devices simultaneously.
    let bob_d1_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 21).await;
    let bob_d2_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 22).await;
    let mut bob_d1_ws = connect_ws(&base, &bob_d1_ticket).await;
    let mut bob_d2_ws = connect_ws(&base, &bob_d2_ticket).await;

    // Charlie connects on TWO devices simultaneously.
    let charlie_d1_ticket =
        common::get_ws_ticket_for_device(&client, &base, &charlie_token, 31).await;
    let charlie_d2_ticket =
        common::get_ws_ticket_for_device(&client, &base, &charlie_token, 32).await;
    let mut charlie_d1_ws = connect_ws(&base, &charlie_d1_ticket).await;
    let mut charlie_d2_ws = connect_ws(&base, &charlie_d2_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_d1_ws).await;
    drain_pending(&mut bob_d2_ws).await;
    drain_pending(&mut charlie_d1_ws).await;
    drain_pending(&mut charlie_d2_ws).await;

    // Distinct per-device ciphertexts for all four recipient device slots.
    let bob_d1_ct = "BOB_D1_CT_GROUP";
    let bob_d2_ct = "BOB_D2_CT_GROUP";
    let charlie_d1_ct = "CHARLIE_D1_CT_GROUP";
    let charlie_d2_ct = "CHARLIE_D2_CT_GROUP";
    let canonical = "CANONICAL_GROUP";

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {
                "21": bob_d1_ct,
                "22": bob_d2_ct,
            },
            charlie_id.to_string(): {
                "31": charlie_d1_ct,
                "32": charlie_d2_ct,
            },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice group send failed");

    // Alice gets the message_sent ack.
    let ack_text = read_text_skipping_presence(&mut alice_ws).await;
    let ack: Value = serde_json::from_str(&ack_text).unwrap();
    assert_eq!(ack["type"], "message_sent");

    // Bob — both devices must receive new_message with their own ciphertext.
    let bob1_text = read_text_skipping_presence(&mut bob_d1_ws).await;
    let bob1: Value = serde_json::from_str(&bob1_text).unwrap();
    assert_eq!(
        bob1["type"], "new_message",
        "bob device 1 should get new_message"
    );
    assert_eq!(
        bob1["content"], bob_d1_ct,
        "bob device 1 must receive its own ciphertext"
    );

    let bob2_text = read_text_skipping_presence(&mut bob_d2_ws).await;
    let bob2: Value = serde_json::from_str(&bob2_text).unwrap();
    assert_eq!(
        bob2["type"], "new_message",
        "bob device 2 should get new_message"
    );
    assert_eq!(
        bob2["content"], bob_d2_ct,
        "bob device 2 must receive its own ciphertext"
    );

    // Charlie — both devices must receive new_message with their own ciphertext.
    let charlie1_text = read_text_skipping_presence(&mut charlie_d1_ws).await;
    let charlie1: Value = serde_json::from_str(&charlie1_text).unwrap();
    assert_eq!(
        charlie1["type"], "new_message",
        "charlie device 1 should get new_message"
    );
    assert_eq!(
        charlie1["content"], charlie_d1_ct,
        "charlie device 1 must receive its own ciphertext"
    );

    let charlie2_text = read_text_skipping_presence(&mut charlie_d2_ws).await;
    let charlie2: Value = serde_json::from_str(&charlie2_text).unwrap();
    assert_eq!(
        charlie2["type"], "new_message",
        "charlie device 2 should get new_message"
    );
    assert_eq!(
        charlie2["content"], charlie_d2_ct,
        "charlie device 2 must receive its own ciphertext"
    );

    // All four ciphertexts must be distinct — guards against any regression
    // that broadcasts a single ciphertext to multiple devices or members.
    assert_ne!(bob1["content"], bob2["content"]);
    assert_ne!(charlie1["content"], charlie2["content"]);
    assert_ne!(bob1["content"], charlie1["content"]);
    assert_ne!(bob1["content"], charlie2["content"]);

    let _ = alice_ws.close(None).await;
    let _ = bob_d1_ws.close(None).await;
    let _ = bob_d2_ws.close(None).await;
    let _ = charlie_d1_ws.close(None).await;
    let _ = charlie_d2_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Group × multi-device fanout — 3-user, asymmetric device counts (#586)
// ---------------------------------------------------------------------------

/// Stronger regression than `test_group_fanout_delivers_to_all_devices_of_all_members`:
/// three group members with asymmetric device counts (bob=2, charlie=3) to catch
/// any short-circuit that skips later members *or* skips the third device of a
/// single member.  Every WS connection must receive exactly its own per-device
/// ciphertext — no device receives another device's ciphertext or the canonical
/// content.  Covers the 3+ member × 2+ device scenario cited in the #586 audit.
#[tokio::test]
async fn test_group_fanout_asymmetric_device_counts() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "gasym_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "gasym_bob").await;
    let (charlie_token, charlie_id, _charlie_name) =
        common::register_and_login(&client, &base, "gasym_charlie").await;

    let group_id = common::create_group(&client, &base, &alice_token, "AsymDevFanoutGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &charlie_id).await;

    // Alice — sender, device 1.
    let alice_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    // Bob — 2 devices (device 11, 12).
    let bob_d1_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 11).await;
    let bob_d2_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 12).await;
    let mut bob_d1_ws = connect_ws(&base, &bob_d1_ticket).await;
    let mut bob_d2_ws = connect_ws(&base, &bob_d2_ticket).await;

    // Charlie — 3 devices (device 21, 22, 23). Having 3 devices (not 2) is the
    // critical difference from the sibling test: a bug that short-circuits after
    // the second device of a member would skip device 23 silently.
    let charlie_d1_ticket =
        common::get_ws_ticket_for_device(&client, &base, &charlie_token, 21).await;
    let charlie_d2_ticket =
        common::get_ws_ticket_for_device(&client, &base, &charlie_token, 22).await;
    let charlie_d3_ticket =
        common::get_ws_ticket_for_device(&client, &base, &charlie_token, 23).await;
    let mut charlie_d1_ws = connect_ws(&base, &charlie_d1_ticket).await;
    let mut charlie_d2_ws = connect_ws(&base, &charlie_d2_ticket).await;
    let mut charlie_d3_ws = connect_ws(&base, &charlie_d3_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_d1_ws).await;
    drain_pending(&mut bob_d2_ws).await;
    drain_pending(&mut charlie_d1_ws).await;
    drain_pending(&mut charlie_d2_ws).await;
    drain_pending(&mut charlie_d3_ws).await;

    let bob_d1_ct = common::dummy_ciphertext("gasym_bob_d11");
    let bob_d2_ct = common::dummy_ciphertext("gasym_bob_d12");
    let charlie_d1_ct = common::dummy_ciphertext("gasym_charlie_d21");
    let charlie_d2_ct = common::dummy_ciphertext("gasym_charlie_d22");
    let charlie_d3_ct = common::dummy_ciphertext("gasym_charlie_d23");
    let alice_d1_ct = common::dummy_ciphertext("gasym_alice_d1");
    let canonical = common::dummy_ciphertext("gasym_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {
                "11": bob_d1_ct.clone(),
                "12": bob_d2_ct.clone(),
            },
            charlie_id.to_string(): {
                "21": charlie_d1_ct.clone(),
                "22": charlie_d2_ct.clone(),
                "23": charlie_d3_ct.clone(),
            },
            alice_id.to_string(): {
                "1": alice_d1_ct.clone(),
            },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice group send failed");

    // Alice — message_sent ack.
    let ack_text = read_text_skipping_presence(&mut alice_ws).await;
    let ack: Value = serde_json::from_str(&ack_text).unwrap();
    assert_eq!(ack["type"], "message_sent", "alice should get message_sent");

    // Bob device 11.
    let bob1_text = read_text_skipping_presence(&mut bob_d1_ws).await;
    let bob1: Value = serde_json::from_str(&bob1_text).unwrap();
    assert_eq!(
        bob1["type"], "new_message",
        "bob d11 should get new_message"
    );
    assert_eq!(
        bob1["content"], bob_d1_ct,
        "bob d11 must receive its own ciphertext"
    );

    // Bob device 12.
    let bob2_text = read_text_skipping_presence(&mut bob_d2_ws).await;
    let bob2: Value = serde_json::from_str(&bob2_text).unwrap();
    assert_eq!(
        bob2["type"], "new_message",
        "bob d12 should get new_message"
    );
    assert_eq!(
        bob2["content"], bob_d2_ct,
        "bob d12 must receive its own ciphertext"
    );

    // Charlie device 21.
    let charlie1_text = read_text_skipping_presence(&mut charlie_d1_ws).await;
    let charlie1: Value = serde_json::from_str(&charlie1_text).unwrap();
    assert_eq!(
        charlie1["type"], "new_message",
        "charlie d21 should get new_message"
    );
    assert_eq!(
        charlie1["content"], charlie_d1_ct,
        "charlie d21 must receive its own ciphertext"
    );

    // Charlie device 22.
    let charlie2_text = read_text_skipping_presence(&mut charlie_d2_ws).await;
    let charlie2: Value = serde_json::from_str(&charlie2_text).unwrap();
    assert_eq!(
        charlie2["type"], "new_message",
        "charlie d22 should get new_message"
    );
    assert_eq!(
        charlie2["content"], charlie_d2_ct,
        "charlie d22 must receive its own ciphertext"
    );

    // Charlie device 23 — the critical third device. A bug that short-circuits
    // after the second device of any member would cause this to deadlock here.
    let charlie3_text = read_text_skipping_presence(&mut charlie_d3_ws).await;
    let charlie3: Value = serde_json::from_str(&charlie3_text).unwrap();
    assert_eq!(
        charlie3["type"], "new_message",
        "charlie d23 should get new_message"
    );
    assert_eq!(
        charlie3["content"], charlie_d3_ct,
        "charlie d23 must receive its own ciphertext"
    );

    // Cross-device and cross-member distinctness.
    assert_ne!(
        bob1["content"], bob2["content"],
        "bob d11 vs d12 must differ"
    );
    assert_ne!(
        charlie1["content"], charlie2["content"],
        "charlie d21 vs d22 must differ"
    );
    assert_ne!(
        charlie1["content"], charlie3["content"],
        "charlie d21 vs d23 must differ"
    );
    assert_ne!(
        charlie2["content"], charlie3["content"],
        "charlie d22 vs d23 must differ"
    );
    assert_ne!(
        bob1["content"], charlie1["content"],
        "bob vs charlie must differ"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_d1_ws.close(None).await;
    let _ = bob_d2_ws.close(None).await;
    let _ = charlie_d1_ws.close(None).await;
    let _ = charlie_d2_ws.close(None).await;
    let _ = charlie_d3_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// #455 / #591 — server-side ciphertext-shape gate on encrypted conversations
// ---------------------------------------------------------------------------

/// Encrypted DM: a `send_message` with plaintext content and no
/// `recipient_device_contents` MUST be rejected with a targeted error.
/// Pre-fix the server stored and broadcast plaintext.
#[tokio::test]
async fn encrypted_dm_rejects_plaintext_send() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "encdm_a").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "encdm_b").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": conv_id,
        "content": "Plaintext on encrypted DM",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("send failed");

    let event = read_text_skipping_presence(&mut alice_ws).await;
    let msg: Value = serde_json::from_str(&event).expect("error JSON parse failed");
    assert_eq!(
        msg["type"], "error",
        "encrypted DM with plaintext must error"
    );
    assert!(
        msg["message"]
            .as_str()
            .unwrap_or("")
            .to_lowercase()
            .contains("ciphertext"),
        "error message should mention 'ciphertext', got: {msg:?}"
    );

    let _ = alice_ws.close(None).await;
}

/// Encrypted DM: even with `recipient_device_contents` populated, payloads
/// that don't base64-decode to a wire-shaped buffer are rejected.
#[tokio::test]
async fn encrypted_dm_rejects_nonciphertext_device_payload() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "encdm2_a").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "encdm2_b").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    // The per-device value is plain ASCII (no 0xEC magic, not normal-msg shape).
    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": conv_id,
        "content": "ignored",
        "recipient_device_contents": {
            bob_id.to_string(): { "0": "ATTACKER_PLAINTEXT" },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("send failed");

    let event = read_text_skipping_presence(&mut alice_ws).await;
    let msg: Value = serde_json::from_str(&event).expect("error JSON parse failed");
    assert_eq!(
        msg["type"], "error",
        "encrypted DM with bad-shape per-device must error"
    );

    let _ = alice_ws.close(None).await;
}

/// Regression for PR #659 reviewer catch: encrypted DMs must also reject
/// plaintext in the canonical `content` field, even when
/// `recipient_device_contents` are valid ciphertext. Otherwise an attacker
/// could pass the gate while smuggling plaintext via `content`, which is
/// persisted and relayed in `NewMessage` events.
#[tokio::test]
async fn encrypted_dm_rejects_plaintext_canonical_content_with_valid_per_device() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "encdm3_a").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "encdm3_b").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    // Per-device value is valid ciphertext (passes the per-device check)
    // but `content` is plaintext — the gate must reject this combination.
    let bob_ct = common::dummy_ciphertext("encdm3_bob");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": conv_id,
        "content": "ATTACKER_PLAINTEXT_IN_CANONICAL",
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("send failed");

    let event = read_text_skipping_presence(&mut alice_ws).await;
    let msg: Value = serde_json::from_str(&event).expect("error JSON parse failed");
    assert_eq!(
        msg["type"], "error",
        "plaintext canonical content must be rejected even with valid per-device ciphertext"
    );

    let _ = alice_ws.close(None).await;
}

/// Encrypted group: the canonical `content` carries the group-key envelope
/// wire and MUST be ciphertext-shaped (#591). Plaintext is rejected.
#[tokio::test]
async fn encrypted_group_rejects_plaintext_send() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "encgrp_a").await;
    let (_bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "encgrp_b").await;

    let group_id = common::create_group(&client, &base, &alice_token, "EncryptedGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    // Flip the group to encrypted directly via the DB so the test doesn't
    // depend on whatever toggle endpoint exists.
    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;
    sqlx::query("UPDATE conversations SET is_encrypted = true WHERE id = $1")
        .bind(uuid::Uuid::parse_str(&group_id).unwrap())
        .execute(&pool)
        .await
        .expect("flip is_encrypted failed");

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": "Plaintext on encrypted group",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("send failed");

    let event = read_text_skipping_presence(&mut alice_ws).await;
    let msg: Value = serde_json::from_str(&event).expect("error JSON parse failed");
    assert_eq!(
        msg["type"], "error",
        "encrypted group with plaintext must error"
    );

    let _ = alice_ws.close(None).await;
}

/// Encrypted group: a wire-shaped `content` is accepted.
#[tokio::test]
async fn encrypted_group_accepts_ciphertext_shaped_content() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "encgrp2_a").await;
    let (_bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "encgrp2_b").await;

    let group_id = common::create_group(&client, &base, &alice_token, "EncryptedGroupOk").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;
    sqlx::query("UPDATE conversations SET is_encrypted = true WHERE id = $1")
        .bind(uuid::Uuid::parse_str(&group_id).unwrap())
        .execute(&pool)
        .await
        .expect("flip is_encrypted failed");

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    drain_pending(&mut alice_ws).await;

    let ct = common::dummy_ciphertext("encgrp_ok");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": ct,
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("send failed");

    let event = read_text_skipping_presence(&mut alice_ws).await;
    let msg: Value = serde_json::from_str(&event).expect("ack JSON parse failed");
    assert_eq!(
        msg["type"], "message_sent",
        "wire-shaped group ciphertext should be accepted"
    );

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Revoked-device fanout filter (#657)
// ---------------------------------------------------------------------------

/// Regression test: ciphertexts addressed to a revoked device must NOT be
/// delivered, while the sibling active device still receives its ciphertext.
///
/// Setup: Alice and Bob are contacts. Bob uploads identity bundles for devices
/// 11 and 22, then revokes device 22. Alice sends with per-device ciphertexts
/// for both 11 and 22. Device 11 MUST receive `new_message`; device 22 MUST
/// NOT receive anything within a 300 ms window.
#[tokio::test]
async fn revoked_device_excluded_from_fanout() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, alice_name) =
        common::register_and_login(&client, &base, "rev657_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "rev657_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Bob registers valid PreKey bundles for device 11 (active) and 22 (to be revoked).
    common::upload_prekey_bundle(&client, &base, &bob_token, 11, 1).await;
    common::upload_prekey_bundle(&client, &base, &bob_token, 22, 1).await;

    // Revoke Bob's device 22.
    let revoke_resp = client
        .delete(format!("{base}/api/keys/device/22"))
        .bearer_auth(&bob_token)
        .send()
        .await
        .expect("revoke request failed");
    assert!(revoke_resp.status().is_success(), "revoke device 22 failed");

    // Alice connects on her device.
    let alice_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;

    // Bob's active device 11 connects.
    let bob_d11_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 11).await;
    let mut bob_d11_ws = connect_ws(&base, &bob_d11_ticket).await;

    // Bob's revoked device 22 also connects (it is still a valid WS session;
    // only the fanout filter should silence it).
    let bob_d22_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 22).await;
    let mut bob_d22_ws = connect_ws(&base, &bob_d22_ticket).await;

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_d11_ws).await;
    drain_pending(&mut bob_d22_ws).await;

    let d11_ct = common::dummy_ciphertext("rev657_d11");
    let d22_ct = common::dummy_ciphertext("rev657_d22");
    let canonical = common::dummy_ciphertext("rev657_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {
                "11": d11_ct.clone(),
                "22": d22_ct.clone(),
            },
            alice_id.to_string(): {
                "1": common::dummy_ciphertext("rev657_alice_d1"),
            },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // Alice gets message_sent.
    let ack = read_text_skipping_presence(&mut alice_ws).await;
    let ack_val: Value = serde_json::from_str(&ack).unwrap();
    assert_eq!(
        ack_val["type"], "message_sent",
        "Alice should get message_sent"
    );

    // Device 11 (active) MUST receive its ciphertext.
    let d11_text = read_text_skipping_presence(&mut bob_d11_ws).await;
    let d11_val: Value = serde_json::from_str(&d11_text).unwrap();
    assert_eq!(
        d11_val["type"], "new_message",
        "device 11 should get new_message"
    );
    assert_eq!(
        d11_val["content"], d11_ct,
        "device 11 must receive its own ciphertext"
    );
    assert_eq!(d11_val["from_username"], alice_name.as_str());

    // Device 22 (revoked) must NOT receive new_message within 300 ms.
    let d22_silent = tokio::time::timeout(
        std::time::Duration::from_millis(300),
        recv_new_message(&mut bob_d22_ws),
    )
    .await;
    assert!(
        d22_silent.is_err(),
        "revoked device 22 must not receive new_message, got: {d22_silent:?}"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_d11_ws.close(None).await;
    let _ = bob_d22_ws.close(None).await;
}

/// Helper: read frames until a `new_message` arrives, ignoring presence noise.
async fn recv_new_message(ws: &mut WsStream) -> Value {
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_ws(base: &str, ticket: &str) -> WsStream {
    let ws_base = base.replace("http://", "ws://");
    let (ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");
    ws
}

/// Read a text message from the WebSocket with a 5-second timeout.
/// Panics if no text message arrives in time.
async fn read_text_with_timeout(ws: &mut WsStream) -> String {
    let timeout = std::time::Duration::from_secs(5);
    loop {
        match tokio::time::timeout(timeout, ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => return text.to_string(),
            Ok(Some(Ok(Message::Ping(_)))) => continue,
            Ok(Some(Ok(Message::Pong(_)))) => continue,
            Ok(Some(Ok(Message::Close(_)))) => {
                panic!("WS connection closed before expected message")
            }
            Ok(Some(Ok(other))) => panic!("Unexpected WS message: {other:?}"),
            Ok(Some(Err(e))) => panic!("WS error: {e}"),
            Ok(None) => panic!("WS stream ended unexpectedly"),
            Err(_) => panic!("Timed out waiting for WS message"),
        }
    }
}

/// Drain any pending messages from the socket (non-blocking).
async fn drain_pending(ws: &mut WsStream) {
    while let Ok(Some(Ok(_))) =
        tokio::time::timeout(std::time::Duration::from_millis(100), ws.next()).await
    {}
}

/// Read frames, skipping `presence` and `presence_list` events. Use when the
/// test expects a non-presence frame.
async fn read_text_skipping_presence(ws: &mut WsStream) -> String {
    loop {
        let text = read_text_with_timeout(ws).await;
        let parsed: serde_json::Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => return text,
        };
        if matches!(
            parsed["type"].as_str(),
            Some("presence") | Some("presence_list")
        ) {
            continue;
        }
        return text;
    }
}

/// Read frames, skipping ambient chatter so the test can wait for a
/// specific downstream event. `delivered` is included because the server
/// emits it back to the sender once the recipient's WS handler observes
/// `new_message`, and that ack often races past `drain_pending`'s 100ms
/// window under tarpaulin/CI pressure.
async fn read_text_skipping_chatter(ws: &mut WsStream) -> String {
    loop {
        let text = read_text_with_timeout(ws).await;
        let parsed: serde_json::Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => return text,
        };
        if matches!(
            parsed["type"].as_str(),
            Some("presence")
                | Some("presence_list")
                | Some("new_message")
                | Some("message_sent")
                | Some("delivered")
        ) {
            continue;
        }
        return text;
    }
}
