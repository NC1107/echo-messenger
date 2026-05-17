//! Integration tests for offline-message replay (`ws/message_service/replay.rs`).
//!
//! Coverage goals:
//! - Reconnect delivers every stored message.
//! - Pagination: > one page of stored messages are all delivered, no duplicates.
//! - `classify_replay_content`: encrypted per-device path, undecryptable path,
//!   and plaintext/group (canonical) path.
//! - `notify_original_senders`: sender receives `delivered` when receiver replays.
//! - Soft-deleted messages are NOT replayed (`deleted_at IS NOT NULL`).
//! - TTL-expired messages are NOT replayed (`expires_at` in the past).

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

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

/// Collect all `new_message` events received within `timeout` from `ws`.
/// Returns a `Vec<Value>` of the parsed frames.
async fn collect_new_messages(ws: &mut WsStream, timeout: std::time::Duration) -> Vec<Value> {
    let mut messages = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                if v["type"] == "new_message" {
                    messages.push(v);
                }
            }
            Ok(Some(Ok(Message::Ping(_) | Message::Pong(_)))) => {}
            Ok(Some(Ok(Message::Close(_)))) | Ok(None) => break,
            Ok(Some(Ok(_))) => {}
            Ok(Some(Err(_))) | Err(_) => break,
        }
    }
    messages
}

// ---------------------------------------------------------------------------
// Test 1 — basic offline replay: all stored messages arrive on reconnect
// ---------------------------------------------------------------------------

/// Alice sends N plaintext group messages while Bob is offline. Bob reconnects
/// and must receive every one of them via the replay path.
#[tokio::test]
async fn offline_replay_delivers_all_stored_messages() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "rpl_basic_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "rpl_basic_bob").await;

    let group_id = common::create_group(&client, &base, &alice_token, "BasicReplayGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    let alice_uuid = uuid::Uuid::parse_str(&alice_id).unwrap();
    let group_uuid = uuid::Uuid::parse_str(&group_id).unwrap();

    // Store 5 messages directly — Bob is offline during this entire window.
    let total: usize = 5;
    for i in 0..total {
        echo_server::db::messages::store_message(
            &pool,
            group_uuid,
            None,
            alice_uuid,
            None,
            &format!("basic-replay-msg-{i}"),
            None,
            None,
        )
        .await
        .expect("store_message failed");
    }

    // Bob connects; replay must deliver all 5 messages.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    let received = collect_new_messages(&mut bob_ws, std::time::Duration::from_secs(10)).await;

    assert_eq!(
        received.len(),
        total,
        "Bob must receive all {total} stored messages on reconnect; got {}",
        received.len()
    );

    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Test 2 — pagination: > one page delivered, no duplicates
// ---------------------------------------------------------------------------

/// Insert UNDELIVERED_PAGE_SIZE + 5 messages (forcing two DB pages) and
/// confirm every message is delivered exactly once.
#[tokio::test]
async fn offline_replay_paginated_no_duplicates() {
    use echo_server::db::messages::UNDELIVERED_PAGE_SIZE;

    let base = common::spawn_server().await;
    let client = Client::new();

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "rpl_page_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "rpl_page_bob").await;

    let group_id =
        common::create_group(&client, &base, &alice_token, "PaginationReplayGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    let alice_uuid = uuid::Uuid::parse_str(&alice_id).unwrap();
    let group_uuid = uuid::Uuid::parse_str(&group_id).unwrap();

    let total = (UNDELIVERED_PAGE_SIZE + 5) as usize;
    for i in 0..total {
        echo_server::db::messages::store_message(
            &pool,
            group_uuid,
            None,
            alice_uuid,
            None,
            &format!("page-replay-msg-{i}"),
            None,
            None,
        )
        .await
        .expect("store_message failed");
    }

    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let ws_base = base.replace("http://", "ws://");
    let (mut bob_ws, _) =
        tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={bob_ticket}"))
            .await
            .expect("Bob WS connect failed");

    // Collect with a generous timeout to absorb multi-page async delivery.
    let received = collect_new_messages(&mut bob_ws, std::time::Duration::from_secs(30)).await;

    assert_eq!(
        received.len(),
        total,
        "Bob must receive all {total} messages across pages; got {}",
        received.len()
    );

    // No duplicates: every message_id must appear exactly once.
    let mut ids: Vec<&Value> = received.iter().map(|v| &v["message_id"]).collect();
    ids.sort_by_key(|v| v.to_string());
    let before = ids.len();
    ids.dedup();
    assert_eq!(
        before,
        ids.len(),
        "duplicate message_ids detected in replay — {} total, {} unique",
        before,
        ids.len()
    );

    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Test 3a — classify_replay_content: Branch C (plaintext / no per-device map)
// ---------------------------------------------------------------------------

/// A plaintext group message carries no `recipient_device_contents`, so
/// `classify_replay_content` falls through to the canonical-content branch.
/// The replayed frame must carry the original text and no `undecryptable` flag.
#[tokio::test]
async fn classify_replay_content_canonical_plaintext() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_tok, _alice_id, _) = common::register_and_login(&client, &base, "cls_c_alice").await;
    let (bob_tok, bob_id, _) = common::register_and_login(&client, &base, "cls_c_bob").await;

    let group = common::create_group(&client, &base, &alice_tok, "ClassifyGroupC").await;
    common::add_member_to_group(&client, &base, &alice_tok, &group, &bob_id).await;

    // Alice sends a plaintext group message while Bob is offline.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_tok).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let plaintext = "plaintext-group-message";
    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "send_message",
                "conversation_id": group,
                "content": plaintext,
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("send failed");
    common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let _ = alice_ws.close(None).await;

    // Bob reconnects — replay must serve canonical content, no undecryptable.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_tok).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    let event = common::recv_until_event(&mut bob_ws, &["new_message"]).await;
    assert_eq!(
        event["content"], plaintext,
        "classify Branch C: must serve canonical plaintext"
    );
    assert!(
        event["undecryptable"].is_null(),
        "classify Branch C: undecryptable must be absent, got: {:?}",
        event["undecryptable"]
    );
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Test 3b — classify_replay_content: Branch A (encrypted, device row present)
// ---------------------------------------------------------------------------

/// When Alice stores a per-device ciphertext for Bob's device 0 and Bob
/// reconnects on device 0, the replay must serve that ciphertext (not the
/// canonical one) with no `undecryptable` flag.
#[tokio::test]
async fn classify_replay_content_encrypted_device_row_present() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_tok, alice_id, _) = common::register_and_login(&client, &base, "cls_a_alice").await;
    let (bob_tok, bob_id, bob_name) = common::register_and_login(&client, &base, "cls_a_bob").await;
    common::make_contacts(&client, &base, &alice_tok, &bob_tok, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_tok).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let canonical = common::dummy_ciphertext("cls_a_canonical");
    let bob_d0_ct = common::dummy_ciphertext("cls_a_bob_d0");
    let alice_d0_ct = common::dummy_ciphertext("cls_a_alice_d0");

    // Bob is offline at send time. Alice sends with a per-device row for Bob device 0.
    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "send_message",
                "to_user_id": bob_id,
                "content": canonical,
                "recipient_device_contents": {
                    bob_id: { "0": bob_d0_ct.clone() },
                    alice_id: { "0": alice_d0_ct },
                },
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("send failed");
    common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let _ = alice_ws.close(None).await;

    // Bob reconnects on device 0 — classify should find the device row and serve it.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_tok).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    let event = common::recv_until_event(&mut bob_ws, &["new_message"]).await;
    assert_eq!(
        event["content"], bob_d0_ct,
        "classify Branch A: must serve the device-specific ciphertext"
    );
    assert!(
        !event["undecryptable"].as_bool().unwrap_or(false),
        "classify Branch A: undecryptable must be false/absent"
    );
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Test 3c — classify_replay_content: Branch B (encrypted, wrong device)
// ---------------------------------------------------------------------------

/// When a per-device row exists for Bob's device 42 but Bob reconnects on
/// device 0 (no row), `classify_replay_content` must emit `undecryptable: true`
/// and must NOT leak the canonical (sender-side) ciphertext.
#[tokio::test]
async fn classify_replay_content_encrypted_wrong_device_undecryptable() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_tok, alice_id, _) = common::register_and_login(&client, &base, "cls_b_alice").await;
    let (bob_tok, bob_id, bob_name) = common::register_and_login(&client, &base, "cls_b_bob").await;
    common::make_contacts(&client, &base, &alice_tok, &bob_tok, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_tok).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let canonical = common::dummy_ciphertext("cls_b_canonical");
    // Only store a per-device row for device 42 — NOT for device 0.
    let bob_d42_ct = common::dummy_ciphertext("cls_b_bob_d42");

    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "send_message",
                "to_user_id": bob_id,
                "content": canonical.clone(),
                "recipient_device_contents": {
                    bob_id: { "42": bob_d42_ct },
                    alice_id: { "0": common::dummy_ciphertext("cls_b_alice_d0") },
                },
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("send failed");
    common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let _ = alice_ws.close(None).await;

    // Bob reconnects on device 0 — no row for it but device 42 has one.
    // classify_replay_content must emit undecryptable=true.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_tok).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    let event = common::recv_until_event(&mut bob_ws, &["new_message"]).await;
    assert_eq!(
        event["undecryptable"], true,
        "classify Branch B: must set undecryptable=true when this device has no row"
    );
    assert_ne!(
        event["content"], canonical,
        "classify Branch B: must NOT serve the canonical (foreign-device) ciphertext"
    );
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Test 4 — notify_original_senders fires on replay
// ---------------------------------------------------------------------------

/// When Bob (offline) reconnects and the server replays a message from Alice,
/// Alice must receive a `delivered` event for that message.
#[tokio::test]
async fn notify_original_senders_on_replay() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "notif_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "notif_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice connects, Bob is offline.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let canonical = common::dummy_ciphertext("notif_canonical");
    let bob_ct = common::dummy_ciphertext("notif_bob_d0");
    let alice_ct = common::dummy_ciphertext("notif_alice_d0");

    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "send_message",
                "to_user_id": bob_id,
                "content": canonical,
                "recipient_device_contents": {
                    bob_id: { "0": bob_ct },
                    alice_id: { "0": alice_ct },
                },
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("Alice send failed");

    // Alice gets her `message_sent` ack; capture the message_id.
    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = ack["message_id"].clone();

    // Bob reconnects — replay fires, which calls notify_original_senders.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    // Wait for Bob to get the replayed message (confirms replay ran).
    common::recv_until_event(&mut bob_ws, &["new_message"]).await;

    // Alice must receive a `delivered` event for the replayed message.
    let delivered_event = common::recv_until_event(&mut alice_ws, &["delivered"]).await;
    assert_eq!(
        delivered_event["message_id"], message_id,
        "Alice must receive delivered event for the replayed message_id"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Test 5 — soft-deleted messages are NOT replayed
// ---------------------------------------------------------------------------

/// A message that has been soft-deleted (`deleted_at IS NOT NULL`) while the
/// recipient is offline must NOT appear in offline replay.
#[tokio::test]
async fn soft_deleted_message_not_replayed() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "softdel_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "softdel_bob").await;

    let group_id = common::create_group(&client, &base, &alice_token, "SoftDeleteGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    let alice_uuid = uuid::Uuid::parse_str(&alice_id).unwrap();
    let group_uuid = uuid::Uuid::parse_str(&group_id).unwrap();

    // Insert two messages: one to be deleted, one to be kept.
    let kept_row = echo_server::db::messages::store_message(
        &pool,
        group_uuid,
        None,
        alice_uuid,
        None,
        "keep-this-message",
        None,
        None,
    )
    .await
    .expect("store kept message failed");

    let deleted_row = echo_server::db::messages::store_message(
        &pool,
        group_uuid,
        None,
        alice_uuid,
        None,
        "delete-this-message",
        None,
        None,
    )
    .await
    .expect("store deleted message failed");

    // Soft-delete the second message directly via SQL.
    sqlx::query("UPDATE messages SET deleted_at = now() WHERE id = $1")
        .bind(deleted_row.id)
        .execute(&pool)
        .await
        .expect("soft delete failed");

    // Bob reconnects — replay must only deliver the kept message.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    let received = collect_new_messages(&mut bob_ws, std::time::Duration::from_secs(10)).await;

    assert_eq!(
        received.len(),
        1,
        "Only 1 message should replay; got {}: {:?}",
        received.len(),
        received
    );
    assert_eq!(
        received[0]["message_id"],
        serde_json::json!(kept_row.id),
        "The replayed message must be the non-deleted one"
    );
    for msg in &received {
        assert_ne!(
            msg["message_id"],
            serde_json::json!(deleted_row.id),
            "Soft-deleted message must not appear in replay"
        );
    }

    let _ = bob_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// Test 6 — TTL-expired messages are NOT replayed
// ---------------------------------------------------------------------------

/// A message whose `expires_at` is in the past must not appear in offline replay
/// once the server's cleanup task has removed it.  We directly expire the row
/// via SQL (set expires_at to a past timestamp) and then call the DB cleanup
/// function to delete it, simulating what the background task would do.
#[tokio::test]
async fn ttl_expired_message_not_replayed() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let database_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .expect("TEST_DATABASE_URL or DATABASE_URL must be set");
    let pool = echo_server::db::create_pool(&database_url).await;

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "ttl_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "ttl_bob").await;

    let group_id = common::create_group(&client, &base, &alice_token, "TtlGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    let alice_uuid = uuid::Uuid::parse_str(&alice_id).unwrap();
    let group_uuid = uuid::Uuid::parse_str(&group_id).unwrap();

    // Store a message that should survive.
    let live_row = echo_server::db::messages::store_message(
        &pool,
        group_uuid,
        None,
        alice_uuid,
        None,
        "live-message",
        None,
        None,
    )
    .await
    .expect("store live message failed");

    // Store a message, then forcibly expire it in the past and run cleanup.
    let expired_row = echo_server::db::messages::store_message(
        &pool,
        group_uuid,
        None,
        alice_uuid,
        None,
        "expired-message",
        None,
        None,
    )
    .await
    .expect("store expired message failed");

    sqlx::query("UPDATE messages SET expires_at = NOW() - INTERVAL '1 second' WHERE id = $1")
        .bind(expired_row.id)
        .execute(&pool)
        .await
        .expect("force-expire message failed");

    // Run the cleanup task — this hard-deletes rows where expires_at <= NOW().
    echo_server::db::messages::cleanup_expired_messages(&pool)
        .await
        .expect("cleanup_expired_messages failed");

    // Bob reconnects; only the live message should appear.
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    let received = collect_new_messages(&mut bob_ws, std::time::Duration::from_secs(10)).await;

    assert_eq!(
        received.len(),
        1,
        "Only the live message should replay; got {}: {:?}",
        received.len(),
        received
    );
    assert_eq!(
        received[0]["message_id"],
        serde_json::json!(live_row.id),
        "The replayed message must be the live one"
    );
    for msg in &received {
        assert_ne!(
            msg["message_id"],
            serde_json::json!(expired_row.id),
            "Expired/deleted message must not appear in replay"
        );
    }

    let _ = bob_ws.close(None).await;
}
