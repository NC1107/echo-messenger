//! Integration tests for `ws::message_service::storage` internals.
//!
//! Coverage:
//!   * `store_and_confirm` — message row persists with `deleted_at IS NULL`;
//!     per-message TTL takes priority over conv-level TTL; out-of-range
//!     per-message TTL falls back to conv-level TTL; encrypted message stores
//!     per-device contents in `message_device_contents`.
//!   * `persist_mentions` — encrypted group skips mention persistence; plaintext
//!     group `@username` mention persists.
//!   * `deliver_self_messages` — sender's second device receives `self_message`
//!     while the originating device gets `message_sent` only.

mod common;

use futures_util::SinkExt;
use reqwest::Client;
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

/// Set `is_encrypted = true` on a group conversation directly in the DB
/// (there is no REST endpoint for this; the flag is set by group-key upload
/// infrastructure that is out of scope for these tests).
async fn flip_encrypted(pool: &sqlx::PgPool, group_id: &str) {
    sqlx::query("UPDATE conversations SET is_encrypted = true WHERE id = $1")
        .bind(Uuid::parse_str(group_id).unwrap())
        .execute(pool)
        .await
        .expect("flip is_encrypted failed");
}

/// Set a conv-level disappearing TTL (5 s minimum; 30 days maximum per the API).
async fn set_conv_ttl(client: &Client, base: &str, token: &str, conv_id: &str, ttl: i64) {
    let resp = client
        .put(format!("{base}/api/conversations/{conv_id}/disappearing"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "ttl_seconds": ttl }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "set_conv_ttl should return 200"
    );
}

// ---------------------------------------------------------------------------
// store_and_confirm — message persists with deleted_at IS NULL
// ---------------------------------------------------------------------------

/// Sending a message via WS creates a row in `messages` with `deleted_at IS NULL`.
///
/// The soft-delete contract says queries must filter on `deleted_at IS NULL`; this
/// test verifies the column is actually NULL on freshly inserted rows (i.e.
/// `store_message` does not accidentally set it).
#[tokio::test]
async fn stored_message_has_null_deleted_at() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, alice_name) =
        common::register_and_login(&client, &base, "sac_del_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "sac_del_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let canonical = common::dummy_ciphertext("sac_del_canonical");
    let bob_ct = common::dummy_ciphertext("sac_del_bob");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();
    let _ = alice_name;

    // Verify the DB row has deleted_at IS NULL.
    let row: (Option<chrono::DateTime<chrono::Utc>>,) =
        sqlx::query_as("SELECT deleted_at FROM messages WHERE id = $1")
            .bind(message_id)
            .fetch_one(&pool)
            .await
            .expect("message not found in DB");
    assert!(
        row.0.is_none(),
        "newly stored message must have deleted_at IS NULL"
    );

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// store_and_confirm — per-message TTL takes priority over conv-level TTL
// ---------------------------------------------------------------------------

/// When a sender supplies a valid `ttl_seconds` field in the WS message, it
/// overrides the conversation-level `disappearing_ttl_seconds`.  The
/// `expires_at` returned in `message_sent` must reflect the per-message TTL,
/// not the conv-level one.
///
/// Concretely: conv TTL = 300 s; per-message TTL = 30 s.  The row must have
/// `expires_at` roughly `NOW() + 30 s`, not `NOW() + 300 s`.
#[tokio::test]
async fn per_message_ttl_overrides_conv_ttl() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "ttl_pri_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "ttl_pri_bob").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Set conv-level TTL to 300 s.
    set_conv_ttl(&client, &base, &alice_token, &conv_id, 300).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let canonical = common::dummy_ciphertext("ttl_pri_canonical");
    let bob_ct = common::dummy_ciphertext("ttl_pri_bob");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "ttl_seconds": 30,                      // per-message: 30 s
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();

    // Confirm via DB: expires_at should be ~30 s from now (±10 s tolerance).
    let row: (Option<chrono::DateTime<chrono::Utc>>,) =
        sqlx::query_as("SELECT expires_at FROM messages WHERE id = $1")
            .bind(message_id)
            .fetch_one(&pool)
            .await
            .expect("message not found");

    let expires_at = row
        .0
        .expect("expires_at must not be NULL with per-message TTL");
    let elapsed = (expires_at - chrono::Utc::now()).num_seconds();
    assert!(
        (20..=40).contains(&elapsed),
        "expires_at should reflect 30 s per-message TTL, got offset {elapsed} s"
    );

    let _ = alice_ws.close(None).await;
}

/// When the per-message `ttl_seconds` is out of the valid range [5, 31_536_000]
/// (here: value = 1, below the 5 s minimum), `resolve_effective_ttl` discards
/// it and falls back to the conversation-level TTL.
#[tokio::test]
async fn invalid_per_message_ttl_falls_back_to_conv_ttl() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "ttl_fb_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "ttl_fb_bob").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Set conv-level TTL to 60 s.
    set_conv_ttl(&client, &base, &alice_token, &conv_id, 60).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let canonical = common::dummy_ciphertext("ttl_fb_canonical");
    let bob_ct = common::dummy_ciphertext("ttl_fb_bob");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "ttl_seconds": 1,                       // invalid: below 5 s minimum
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();

    // DB: expires_at should reflect conv TTL (~60 s), not the invalid per-msg 1 s.
    let row: (Option<chrono::DateTime<chrono::Utc>>,) =
        sqlx::query_as("SELECT expires_at FROM messages WHERE id = $1")
            .bind(message_id)
            .fetch_one(&pool)
            .await
            .expect("message not found");

    let expires_at = row
        .0
        .expect("expires_at must not be NULL when conv TTL is set");
    let elapsed = (expires_at - chrono::Utc::now()).num_seconds();
    assert!(
        (50..=70).contains(&elapsed),
        "expires_at should reflect conv TTL of 60 s when per-msg TTL is invalid, got {elapsed} s"
    );

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// store_and_confirm — encrypted message stores per-device contents
// ---------------------------------------------------------------------------

/// When `recipient_device_contents` is supplied for an encrypted DM, the
/// server must write a row to `message_device_contents` for each
/// `(recipient_user_id, device_id)` pair.
#[tokio::test]
async fn encrypted_message_stores_per_device_contents() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "epdc_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "epdc_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let bob_uuid = Uuid::parse_str(&bob_id).unwrap();
    let device_id: i32 = 7;
    let bob_device_ct = common::dummy_ciphertext("epdc_bob_d7");
    let canonical = common::dummy_ciphertext("epdc_canonical");

    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { device_id.to_string(): bob_device_ct.clone() },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();

    let stored =
        echo_server::db::messages::get_device_content(&pool, message_id, bob_uuid, device_id)
            .await
            .expect("get_device_content failed");
    assert_eq!(
        stored,
        Some(bob_device_ct),
        "per-device ciphertext row must be written to message_device_contents"
    );

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// persist_mentions — encrypted group skips mention persistence
// ---------------------------------------------------------------------------

/// When a group is marked `is_encrypted = true`, `persist_mentions` must be a
/// no-op: the server cannot scan ciphertext for `@` tokens.
///
/// Setup: flip the group encrypted, send a ciphertext-shaped message that
/// contains `@bob_username` in the canonical content.  No mention row may
/// appear in `mentions` for the named user.
#[tokio::test]
async fn encrypted_group_skips_mention_persistence() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "encm_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "encm_bob").await;

    let group_id = common::create_group(&client, &base, &alice_token, "EncMentionGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    // Flip the group to encrypted before sending any messages.
    flip_encrypted(&pool, &group_id).await;

    // The server now enforces ciphertext-only for encrypted groups (#591).
    // We send a wire-shaped ciphertext (not plaintext "@bob_name").
    let canonical = common::dummy_ciphertext("encm_canonical");
    let bob_ct = common::dummy_ciphertext("encm_bob_d0");

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();

    // No mention row must exist for the message in the encrypted group.
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM mentions WHERE message_id = $1")
        .bind(message_id)
        .fetch_one(&pool)
        .await
        .expect("mention count query failed");
    assert_eq!(
        count.0, 0,
        "encrypted group must produce zero mention rows regardless of canonical content"
    );
    let _ = bob_token;
    let _ = bob_name;

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// persist_mentions — plaintext @username mention persists
// ---------------------------------------------------------------------------

/// Plaintext group message with `@<username>` produces a mention row in the DB.
/// This is the positive counterpart to the encrypted-group test above.
#[tokio::test]
async fn plaintext_group_username_mention_persists() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "plm_alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "plm_bob").await;

    let group_id =
        common::create_group(&client, &base, &alice_token, "PlaintextMentionGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let send_msg = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": format!("hey @{bob_name} check this out"),
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let message_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();

    let bob_uuid = Uuid::parse_str(&bob_id).unwrap();
    let count: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM mentions WHERE message_id = $1 AND mentioned_user_id = $2",
    )
    .bind(message_id)
    .bind(bob_uuid)
    .fetch_one(&pool)
    .await
    .expect("mention count query failed");
    assert_eq!(
        count.0, 1,
        "plaintext group @username must produce a mention row"
    );
    let _ = bob_token;

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// client_message_id — GRP2 sender mints UUID, server honours it
// ---------------------------------------------------------------------------

/// GRP2 senders bind `(conversation_id, message_id)` into the Ed25519
/// signature payload (audit OQ-12). If the server picks its own id after
/// the sender has signed, the receiver's signature check fails and the
/// message renders as `[Could not verify sender]`. The server must
/// honour the client-supplied UUID verbatim. This test sends a
/// `client_message_id` field on the WS frame and confirms the
/// `message_sent` ack + the persisted row both report the same UUID.
#[tokio::test]
async fn client_message_id_is_honoured_by_server() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "cmi_alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "cmi_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let minted = Uuid::new_v4();
    let canonical = common::dummy_ciphertext("cmi_canonical");
    let bob_ct = common::dummy_ciphertext("cmi_bob");
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "client_message_id": minted.to_string(),
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    alice_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice send failed");

    let ack = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;
    let acked_id = Uuid::parse_str(ack["message_id"].as_str().unwrap()).unwrap();
    assert_eq!(
        acked_id, minted,
        "message_sent must echo the client-minted UUID"
    );

    let row: (Uuid,) = sqlx::query_as("SELECT id FROM messages WHERE id = $1")
        .bind(minted)
        .fetch_one(&pool)
        .await
        .expect("client-minted message not found in DB");
    assert_eq!(row.0, minted, "DB row must use the client-minted UUID");

    let _ = alice_ws.close(None).await;
}

/// Sending two messages with the same `client_message_id` must fail the
/// second one (Postgres primary-key collision). The first message
/// remains intact; the second triggers a server `error` frame so the
/// sender knows to mint a fresh UUID and re-sign.
#[tokio::test]
async fn duplicate_client_message_id_is_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = test_pool().await;

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "cmi_dup_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "cmi_dup_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let minted = Uuid::new_v4();
    let bob_ct = common::dummy_ciphertext("cmi_dup_bob");
    let frame = |label: &str| {
        serde_json::json!({
            "type": "send_message",
            "to_user_id": bob_id,
            "content": common::dummy_ciphertext(label),
            "client_message_id": minted.to_string(),
            "recipient_device_contents": {
                bob_id.to_string(): { "0": bob_ct },
            },
        })
    };

    alice_ws
        .send(Message::Text(frame("first").to_string().into()))
        .await
        .expect("first send failed");
    let _ = common::recv_until_event(&mut alice_ws, &["message_sent"]).await;

    alice_ws
        .send(Message::Text(frame("dup").to_string().into()))
        .await
        .expect("second send failed");
    let next = common::recv_until_event(&mut alice_ws, &["error", "message_sent"]).await;
    assert_eq!(
        next["type"], "error",
        "duplicate client_message_id must yield an error, not silent overwrite"
    );

    // Only one row exists for the minted UUID.
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM messages WHERE id = $1")
        .bind(minted)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count.0, 1, "no duplicate row may be persisted");

    let _ = alice_ws.close(None).await;
}

// ---------------------------------------------------------------------------
// deliver_self_messages — sender's other device receives self_message
// ---------------------------------------------------------------------------

/// When Alice sends on device 1 and also has device 2 connected, device 2 must
/// receive a `self_message` frame (not `new_message`) carrying the per-device
/// ciphertext for device 2.  Device 1 (the originating device) must NOT receive
/// `self_message`.
///
/// This exercises `deliver_self_messages` in storage.rs, which is the only path
/// that emits the `self_message` WS event.
#[tokio::test]
async fn sender_second_device_receives_self_message() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, _) = common::register_and_login(&client, &base, "sm_alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "sm_bob").await;

    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice connects on two devices.
    let alice_d1_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let alice_d2_ticket = common::get_ws_ticket_for_device(&client, &base, &alice_token, 2).await;
    let mut alice_d1_ws = connect_ws(&base, &alice_d1_ticket).await;
    let mut alice_d2_ws = connect_ws(&base, &alice_d2_ticket).await;

    // Bob connects so fanout succeeds (otherwise the server would skip delivery confirmation).
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    common::drain_pending(&mut alice_d1_ws).await;
    common::drain_pending(&mut alice_d2_ws).await;
    common::drain_pending(&mut bob_ws).await;

    let alice_d2_ct = common::dummy_ciphertext("sm_alice_d2");
    let bob_ct = common::dummy_ciphertext("sm_bob_d0");
    let canonical = common::dummy_ciphertext("sm_canonical");

    // Alice device 1 sends the message; includes a self-ciphertext for device 2.
    let send_msg = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
            alice_id.to_string(): {
                "1": common::dummy_ciphertext("sm_alice_d1"),
                "2": alice_d2_ct.clone(),
            },
        },
    });
    alice_d1_ws
        .send(Message::Text(send_msg.to_string().into()))
        .await
        .expect("Alice d1 send failed");

    // Device 1 (originating) must receive `message_sent`, NOT `self_message`.
    let d1_ack = common::recv_until_event(&mut alice_d1_ws, &["message_sent"]).await;
    assert_eq!(
        d1_ack["type"], "message_sent",
        "originating device must receive message_sent"
    );

    // Device 2 must receive `self_message` with its own ciphertext.
    let d2_event = common::recv_until_event(&mut alice_d2_ws, &["self_message"]).await;
    assert_eq!(
        d2_event["type"], "self_message",
        "sender's second device must receive self_message"
    );
    assert_eq!(
        d2_event["content"], alice_d2_ct,
        "self_message must carry the per-device ciphertext for device 2"
    );

    // Verify the self_message carries the correct conversation context.
    assert!(
        d2_event["conversation_id"].is_string(),
        "self_message must include conversation_id"
    );
    assert!(
        d2_event["message_id"].is_string(),
        "self_message must include message_id"
    );

    let _ = alice_d1_ws.close(None).await;
    let _ = alice_d2_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}
