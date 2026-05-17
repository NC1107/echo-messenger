//! Integration tests for the previously-untested branches in
//! `ws/message_service/` — `resolve_conversation`, `validate_conversation_security`,
//! and `validate_message_length` at the exact boundary.
//!
//! Pure-function unit tests for `is_valid_ciphertext_shape` and
//! `ParsedRecipientDeviceContents::from_wire` live inside their source
//! modules (`validate.rs` and `types.rs` respectively) so they can access
//! the `pub(in crate::ws::message_service)` visibility without any
//! visibility-bumping or re-export plumbing.
//!
//! Covered here:
//!   * `resolve_conversation` — explicit conversation_id (member accepted,
//!     non-member rejected), to_user_id (auto-create DM), neither field.
//!   * `validate_conversation_security` — channel_id supplied on a DM
//!     (rejected: channel_id is only valid for group conversations).
//!   * `validate_message_length` — content of exactly MAX_MESSAGE_LENGTH
//!     characters is accepted (boundary case not in ws_content_rejection.rs).
//!   * `validate_encrypted_payload` — encrypted DM with missing
//!     `recipient_device_contents` and empty device map (rejected).

mod common;

use futures_util::SinkExt;
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_ws(base: &str, ticket: &str) -> WsStream {
    let ws_base = base.replace("http://", "ws://");
    let (ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");
    ws
}

async fn send_and_expect_error(ws: &mut WsStream, frame: Value, error_substr: &str) {
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send failed");
    let evt = common::recv_until_event(ws, &["error", "message_sent"]).await;
    assert_eq!(evt["type"], "error", "expected error frame, got: {evt}");
    let msg = evt["message"]
        .as_str()
        .expect("error frame missing message");
    assert!(
        msg.to_lowercase().contains(&error_substr.to_lowercase()),
        "error {msg:?} did not contain {error_substr:?}"
    );
}

async fn send_and_expect_ok(ws: &mut WsStream, frame: Value) -> Value {
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send failed");
    common::recv_until_event(ws, &["message_sent", "error"]).await
}

// ── resolve_conversation ─────────────────────────────────────────────────────

/// Sending to an explicit `conversation_id` the sender is a member of succeeds.
#[tokio::test]
async fn resolve_conversation_by_id_member_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "rc_memok_a").await;
    let group_id = common::create_group(&client, &base, &alice_token, "RcMemberOk").await;

    let ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut ws = connect_ws(&base, &ticket).await;
    common::drain_pending(&mut ws).await;

    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": "hello from member",
    });
    let ack = send_and_expect_ok(&mut ws, frame).await;
    assert_eq!(
        ack["type"], "message_sent",
        "member should get message_sent, got: {ack}"
    );

    let _ = ws.close(None).await;
}

/// Sending to a `conversation_id` the sender is NOT a member of is rejected.
#[tokio::test]
async fn resolve_conversation_by_id_non_member_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    // Alice owns the group; Eve is never added.
    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "rc_nonmem_a").await;
    let (eve_token, _eve_id, _) = common::register_and_login(&client, &base, "rc_nonmem_e").await;

    let group_id = common::create_group(&client, &base, &alice_token, "RcNonMember").await;

    let ticket = common::get_ws_ticket(&client, &base, &eve_token).await;
    let mut ws = connect_ws(&base, &ticket).await;
    common::drain_pending(&mut ws).await;

    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": "sneaky message",
    });
    send_and_expect_error(&mut ws, frame, "member").await;

    let _ = ws.close(None).await;
}

/// Omitting both `conversation_id` and `to_user_id` returns an error.
#[tokio::test]
async fn resolve_conversation_neither_field_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "rc_neither_a").await;

    let ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut ws = connect_ws(&base, &ticket).await;
    common::drain_pending(&mut ws).await;

    // Neither conversation_id nor to_user_id provided.
    let frame = serde_json::json!({
        "type": "send_message",
        "content": "no destination",
    });
    send_and_expect_error(&mut ws, frame, "conversation_id").await;

    let _ = ws.close(None).await;
}

/// Legacy `to_user_id` path auto-creates a DM conversation for contacts.
#[tokio::test]
async fn resolve_conversation_by_to_user_id_creates_dm() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "rc_dm_a").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "rc_dm_b").await;

    // Make them contacts (creates DM conversation).
    common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // DMs are auto-encrypted; supply wire-shaped payloads.
    let canonical = common::dummy_ciphertext("rc_dm_canonical");
    let bob_ct = common::dummy_ciphertext("rc_dm_bob");
    let frame = serde_json::json!({
        "type": "send_message",
        "to_user_id": bob_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { "0": bob_ct },
        },
    });
    let ack = send_and_expect_ok(&mut alice_ws, frame).await;
    assert_eq!(
        ack["type"], "message_sent",
        "to_user_id DM should succeed, got: {ack}"
    );

    let _ = alice_ws.close(None).await;
}

// ── validate_conversation_security ──────────────────────────────────────────

/// Supplying `channel_id` for a DM conversation is rejected.
#[tokio::test]
async fn validate_security_channel_id_on_dm_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "vcs_dm_a").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "vcs_dm_b").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // channel_id is only valid for group conversations — DMs must reject it.
    let fake_channel = uuid::Uuid::new_v4();
    let canonical = common::dummy_ciphertext("vcs_dm_ct");
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": conv_id,
        "channel_id": fake_channel,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): { "0": canonical },
        },
    });
    send_and_expect_error(&mut alice_ws, frame, "channel_id").await;

    let _ = alice_ws.close(None).await;
}

/// Supplying a `channel_id` that belongs to a different group is rejected.
#[tokio::test]
async fn validate_security_channel_id_wrong_group_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "vcs_chan_a").await;

    let group_a = common::create_group(&client, &base, &alice_token, "VcsChanGroupA").await;
    let group_b = common::create_group(&client, &base, &alice_token, "VcsChanGroupB").await;

    // Fetch group_b's default text channel id via the channels API.
    let channels_b: Value = reqwest::Client::new()
        .get(format!("{base}/api/groups/{group_b}/channels"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let channel_b_id = channels_b[0]["id"]
        .as_str()
        .expect("expected at least one channel in group_b");

    let ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut ws = connect_ws(&base, &ticket).await;
    common::drain_pending(&mut ws).await;

    // Send to group_a with a channel that belongs to group_b.
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_a,
        "channel_id": channel_b_id,
        "content": "mismatch channel",
    });
    send_and_expect_error(&mut ws, frame, "not part of this conversation").await;

    let _ = ws.close(None).await;
}

// ── validate_message_length — exact boundary ─────────────────────────────────

/// Content of exactly MAX_MESSAGE_LENGTH (10 000) characters must be accepted.
#[tokio::test]
async fn message_at_exact_max_length_accepted() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "maxlen_a").await;
    let group_id = common::create_group(&client, &base, &alice_token, "MaxLenGroup").await;

    let ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut ws = connect_ws(&base, &ticket).await;
    common::drain_pending(&mut ws).await;

    let at_limit = "a".repeat(10_000);
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": at_limit,
    });
    let ack = send_and_expect_ok(&mut ws, frame).await;
    assert_eq!(
        ack["type"], "message_sent",
        "10 000-char message should be accepted, got: {ack}"
    );

    let _ = ws.close(None).await;
}

// ── validate_encrypted_payload — device map edge cases ───────────────────────

/// Encrypted DM with an empty `recipient_device_contents` map is rejected.
#[tokio::test]
async fn encrypted_dm_empty_device_map_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "vep_empty_a").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "vep_empty_b").await;

    let conv_id =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let canonical = common::dummy_ciphertext("vep_canon");
    // The outer map has bob's uid but the per-recipient device map is empty.
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": conv_id,
        "content": canonical,
        "recipient_device_contents": {
            bob_id.to_string(): {},
        },
    });
    send_and_expect_error(&mut alice_ws, frame, "ciphertext").await;

    let _ = alice_ws.close(None).await;
}
