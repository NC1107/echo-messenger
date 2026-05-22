//! Phase 1.5 (audit P1-2) — server-side enforcement that the sender of a
//! group message is actually a current member of the conversation.
//!
//! The design doc is `docs/group-e2e-design/04-migration-plan.md` §"Phase 1.5"
//! and the attack model is `docs/group-e2e-design/05-message-loss-analysis.md` L2
//! ("removed member tries to send").
//!
//! The check ships as `enforce_group_sender_membership` in
//! `apps/server/src/ws/message_service/validate.rs`. It runs on the
//! encrypted-group send branch only — plaintext groups and 1:1 DMs are
//! out of scope (DMs are contact-gated; plaintext groups are GRP1's
//! threat-model peer of "no E2E to enforce on").
//!
//! Covered:
//!   * member can send to their encrypted group → `message_sent`
//!   * non-member sending to a group they were never in → rejected, nothing persisted
//!   * member who was just kicked → rejected, nothing persisted
//!   * member sending to a plaintext (downgraded) group → still works
//!
//! Send transport is WebSocket — the Echo server has no REST send-message
//! endpoint, every send flows through the `send_message` WS frame handled
//! by `ws::message_service::handle_send_message`.

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

async fn fetch_history(client: &Client, base: &str, token: &str, conv: &str) -> Vec<Value> {
    let resp = client
        .get(format!("{base}/api/messages/{conv}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    resp.json::<Vec<Value>>().await.unwrap()
}

/// Drive a `send_message` frame and read frames until either `message_sent`
/// or `error` arrives. Skips presence chatter the test isn't interested in.
async fn send_and_recv_outcome(ws: &mut WsStream, frame: Value) -> Value {
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send failed");
    common::recv_until_event(ws, &["error", "message_sent"]).await
}

/// Member of an encrypted group can send: outcome is `message_sent` and
/// the message lands in history.
#[tokio::test]
async fn member_can_send_to_encrypted_group() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "smemenc_alice").await;
    let group = common::create_group(&client, &base, &alice_token, "EncryptedSendMembership").await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // `create_group` defaults `is_encrypted = true` (Phase 5), so a wire-
    // shaped ciphertext payload is required to clear the shape gate.
    let ciphertext = common::dummy_ciphertext("smemenc_alice_payload");
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": ciphertext,
    });

    let outcome = send_and_recv_outcome(&mut alice_ws, frame).await;
    assert_eq!(
        outcome["type"], "message_sent",
        "encrypted-group send by a current member should succeed, got: {outcome}"
    );

    // Sanity: the message is persisted to history.
    let history = fetch_history(&client, &base, &alice_token, &group).await;
    assert_eq!(
        history.len(),
        1,
        "expected one persisted message, got: {history:?}"
    );

    let _ = alice_ws.close(None).await;
}

/// A user who is NOT a member of an encrypted group cannot send to it via
/// `send_message`. The server emits an error frame and the message is not
/// persisted. Either error string is acceptable — the `sender-not-member`
/// code is the structured signal but `resolve_conversation` runs an
/// upstream `is_member` check that returns "Not a member of this
/// conversation" first.  Both rejections satisfy the security property the
/// audit P1-2 ticket cares about.
#[tokio::test]
async fn non_member_cannot_send_to_encrypted_group() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_token, _owner_id, _) =
        common::register_and_login(&client, &base, "smnonmem_owner").await;
    let (mallory_token, _mallory_id, _) =
        common::register_and_login(&client, &base, "smnonmem_mallory").await;

    let group = common::create_group(&client, &base, &owner_token, "NonMemberSendBlocked").await;

    let mallory_ticket = common::get_ws_ticket(&client, &base, &mallory_token).await;
    let mut mallory_ws = connect_ws(&base, &mallory_ticket).await;
    common::drain_pending(&mut mallory_ws).await;

    let ciphertext = common::dummy_ciphertext("smnonmem_mallory_payload");
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": ciphertext,
    });

    let outcome = send_and_recv_outcome(&mut mallory_ws, frame).await;
    assert_eq!(
        outcome["type"], "error",
        "non-member send to encrypted group must be rejected, got: {outcome}"
    );
    let msg = outcome["message"]
        .as_str()
        .expect("error frame missing message")
        .to_lowercase();
    assert!(
        msg.contains("sender-not-member") || msg.contains("not a member"),
        "rejection message {msg:?} should signal membership failure",
    );

    // No history rows from a non-member send.
    let history = fetch_history(&client, &base, &owner_token, &group).await;
    assert!(
        history.is_empty(),
        "non-member rejected send must not persist, history: {history:?}"
    );

    let _ = mallory_ws.close(None).await;
}

/// A member who was just kicked from an encrypted group can no longer send.
/// This is the canonical attack covered by Phase 1.5: ex-member retains
/// a stale group key but the server must refuse to relay their ciphertext.
#[tokio::test]
async fn kicked_member_cannot_send_to_encrypted_group() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (owner_token, _owner_id, _) =
        common::register_and_login(&client, &base, "smkick_owner").await;
    let (victim_token, victim_id, _) =
        common::register_and_login(&client, &base, "smkick_victim").await;

    let group = common::create_group(&client, &base, &owner_token, "KickedSendBlocked").await;
    common::add_member_to_group(&client, &base, &owner_token, &group, &victim_id).await;

    // Sanity: while still a member, victim can send.
    let victim_ticket = common::get_ws_ticket(&client, &base, &victim_token).await;
    let mut victim_ws = connect_ws(&base, &victim_ticket).await;
    common::drain_pending(&mut victim_ws).await;

    let pre_kick_ct = common::dummy_ciphertext("smkick_pre");
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": pre_kick_ct,
    });
    let outcome = send_and_recv_outcome(&mut victim_ws, frame).await;
    assert_eq!(
        outcome["type"], "message_sent",
        "pre-kick send by an active member must succeed, got: {outcome}"
    );

    // Kick.
    let resp = client
        .delete(format!("{base}/api/groups/{group}/members/{victim_id}"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "kick should succeed");

    common::drain_pending(&mut victim_ws).await;

    // Post-kick send must be rejected.
    let post_kick_ct = common::dummy_ciphertext("smkick_post");
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": post_kick_ct,
    });
    let outcome = send_and_recv_outcome(&mut victim_ws, frame).await;
    assert_eq!(
        outcome["type"], "error",
        "post-kick send must be rejected, got: {outcome}"
    );
    let msg = outcome["message"]
        .as_str()
        .expect("error frame missing message")
        .to_lowercase();
    assert!(
        msg.contains("sender-not-member") || msg.contains("not a member"),
        "post-kick rejection message {msg:?} should signal membership failure",
    );

    // Verify the post-kick payload was NOT persisted. The group also has
    // server-generated `__system__:member_joined` / `member_removed` rows
    // from the lifecycle events, so filter those out and assert only the
    // pre-kick payload remains among real user messages.
    let history = fetch_history(&client, &base, &owner_token, &group).await;
    let user_messages: Vec<&Value> = history
        .iter()
        .filter(|m| {
            !m["content"]
                .as_str()
                .unwrap_or("")
                .starts_with("__system__:")
        })
        .collect();
    assert_eq!(
        user_messages.len(),
        1,
        "only the pre-kick user message should be in history, got: {user_messages:?}"
    );
    let only_content = user_messages[0]["content"].as_str().unwrap_or("");
    assert_eq!(
        only_content, pre_kick_ct,
        "the persisted user message must be the pre-kick one"
    );
    let post_kick_present = history
        .iter()
        .any(|m| m["content"].as_str() == Some(post_kick_ct.as_str()));
    assert!(
        !post_kick_present,
        "post-kick rejected ciphertext must not be persisted, history: {history:?}"
    );

    let _ = victim_ws.close(None).await;
}

/// Plaintext groups are explicitly out of scope for the encrypted-only
/// Phase 1.5 gate: a current member's send must still succeed and persist
/// without the ciphertext-shape requirement.
#[tokio::test]
async fn member_can_send_to_plaintext_group() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "smplain_alice").await;
    let group = common::create_plaintext_group(&client, &base, &alice_token, "PlaintextSend").await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group,
        "content": "hello plaintext group",
    });
    let outcome = send_and_recv_outcome(&mut alice_ws, frame).await;
    assert_eq!(
        outcome["type"], "message_sent",
        "plaintext-group send by a member must succeed, got: {outcome}"
    );

    let history = fetch_history(&client, &base, &alice_token, &group).await;
    assert_eq!(
        history.len(),
        1,
        "expected one persisted message, got: {history:?}"
    );
    assert_eq!(history[0]["content"], "hello plaintext group");

    let _ = alice_ws.close(None).await;
}
