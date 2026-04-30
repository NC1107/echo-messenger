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

    let (alice_token, _alice_id, alice_name) =
        common::register_and_login(&client, &base, "alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": "Hello from integration test!",
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
        bob_msg["content"], "Hello from integration test!",
        "Message content should match"
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
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
    let bob_event = read_text_with_timeout(&mut bob_ws).await;
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // Alice sends a message to create some content to read
    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": conv_id,
        "content": "hello for read receipt test",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    // Drain the message_sent and new_message events
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
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
    let alice_event = read_text_with_timeout(&mut alice_ws).await;
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
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
    let bob_event = read_text_with_timeout(&mut bob_ws).await;
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
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
// Per-recipient delivery: offline member gets replay when peer was online
// ---------------------------------------------------------------------------

/// Regression test for the global `delivered` flag bug.
///
/// Scenario: Alice sends a group message while Bob is online and Charlie is
/// offline. Bob receives it live (which used to set `delivered = true` globally).
/// When Charlie reconnects, he must still receive the message via offline
/// replay. Under the old schema Charlie would permanently miss the message
/// because `get_undelivered` filtered on `delivered = false`.
#[tokio::test]
async fn group_offline_member_gets_replay_when_peer_was_online() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "orpalice").await;
    let (bob_token, bob_id, _bob_name) = common::register_and_login(&client, &base, "orpbob").await;
    let (charlie_token, charlie_id, _charlie_name) =
        common::register_and_login(&client, &base, "orpcharlie").await;

    let group_id = common::create_group(&client, &base, &alice_token, "OfflineReplayGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &charlie_id).await;

    // All three connect initially so presence noise drains.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let charlie_ticket = common::get_ws_ticket(&client, &base, &charlie_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    let mut charlie_ws = connect_ws(&base, &charlie_ticket).await;

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;
    drain_pending(&mut charlie_ws).await;

    // Charlie goes offline before the message is sent.
    let _ = charlie_ws.close(None).await;
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    // Alice sends a message while only Bob is online.
    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": "charlie should see this on reconnect",
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice group send failed");

    // Alice gets message_sent, Bob gets new_message (live delivery).
    let alice_event = read_text_skipping_presence(&mut alice_ws).await;
    let alice_msg: Value = serde_json::from_str(&alice_event).unwrap();
    assert_eq!(
        alice_msg["type"], "message_sent",
        "Alice should get message_sent"
    );

    let bob_event = read_text_skipping_presence(&mut bob_ws).await;
    let bob_msg: Value = serde_json::from_str(&bob_event).unwrap();
    assert_eq!(
        bob_msg["type"], "new_message",
        "Bob should get new_message live"
    );
    assert_eq!(bob_msg["content"], "charlie should see this on reconnect");

    // Small delay to ensure the delivery receipt is recorded before Charlie reconnects.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    // Charlie reconnects — offline replay must deliver the missed message.
    let charlie_ticket2 = common::get_ws_ticket(&client, &base, &charlie_token).await;
    let mut charlie_ws2 = connect_ws(&base, &charlie_ticket2).await;

    let charlie_event = read_text_skipping_presence(&mut charlie_ws2).await;
    let charlie_msg: Value = serde_json::from_str(&charlie_event).unwrap();
    assert_eq!(
        charlie_msg["type"], "new_message",
        "Charlie must receive the missed message on reconnect"
    );
    assert_eq!(
        charlie_msg["content"], "charlie should see this on reconnect",
        "Replayed message content must match"
    );
    assert_eq!(
        charlie_msg["conversation_id"],
        group_id.as_str(),
        "Replayed message must carry the correct conversation_id"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
    let _ = charlie_ws2.close(None).await;
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drain_pending(&mut alice_ws).await;

    // Bob has device_id=42 in this simulation; the test WS path uses device_id=0
    // (the default when no key bundle is registered).
    let bob_device_id: i32 = 42;
    let canonical_ct = "CANONICAL_CIPHERTEXT";
    let device_ct = "BOB_DEVICE_42_CIPHERTEXT";

    // Alice sends a message while Bob is offline, including per-device content.
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical_ct,
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

    let bob_event = read_text_with_timeout(&mut bob_ws).await;
    let bob_msg: Value = serde_json::from_str(&bob_event).expect("Bob JSON parse failed");
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
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drain_pending(&mut alice_ws).await;

    // Both alice and bob use device_id=1 — this is the exact collision case
    // that the recipient-scoped storage fix (#522) must resolve.
    let device_id: i32 = 1;
    let bob_device_ct = "BOB_DEVICE_1_CIPHERTEXT";
    let alice_device_ct = "ALICE_DEVICE_1_CIPHERTEXT";
    let canonical = "CANONICAL";

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { device_id.to_string(): bob_device_ct },
            alice_id.to_string(): { device_id.to_string(): alice_device_ct },
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
        Some(bob_device_ct.to_string()),
        "Bob's device-1 ciphertext must be stored"
    );

    let alice_stored =
        echo_server::db::messages::get_device_content(&pool, message_id, alice_uuid, device_id)
            .await
            .expect("db query failed");
    assert_eq!(
        alice_stored,
        Some(alice_device_ct.to_string()),
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

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_d1_ws).await;
    drain_pending(&mut bob_d2_ws).await;

    let bob_d1_ct = "BOB_D1_CT_557";
    let bob_d2_ct = "BOB_D2_CT_557";
    let canonical = "CANONICAL_557";

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {
                "11": bob_d1_ct,
                "22": bob_d2_ct,
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

/// Read frames from the socket, skipping any `presence` events, until a
/// non-presence text frame arrives. Presence events can race in late under
/// slower runtimes (tarpaulin coverage instrumentation, CI pressure) and
/// should not cause flakes in tests that assert other event types.
async fn read_text_skipping_presence(ws: &mut WsStream) -> String {
    loop {
        let text = read_text_with_timeout(ws).await;
        let parsed: serde_json::Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => return text,
        };
        if parsed["type"] == "presence" {
            continue;
        }
        return text;
    }
}
