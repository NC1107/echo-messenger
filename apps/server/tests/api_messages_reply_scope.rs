//! Integration tests for #519: reply targets must be scoped to a single
//! conversation.  Sending a message that replies to a parent in a *different*
//! conversation must be rejected, and the thread-replies endpoint must never
//! surface replies that live outside the parent's conversation.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
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

async fn drain_pending(ws: &mut WsStream) {
    while let Ok(Some(Ok(_))) = tokio::time::timeout(Duration::from_millis(150), ws.next()).await {}
}

/// Read text frames until we see one whose `type` matches `wanted`.
/// Skips presence/typing chatter and per-device echo frames.
async fn wait_for_event(ws: &mut WsStream, wanted: &[&str]) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let next = tokio::time::timeout_at(deadline, ws.next())
            .await
            .expect("timed out waiting for event");
        let frame = next.expect("WS stream closed").expect("WS error");
        if let Message::Text(text) = frame
            && let Ok(v) = serde_json::from_str::<Value>(&text)
            && let Some(t) = v["type"].as_str()
            && wanted.contains(&t)
        {
            return v;
        }
    }
}

/// Send a `send_message` frame and return the resulting `message_sent`
/// confirmation's `message_id` (as String).  Panics if an `error` frame
/// arrives instead.
///
/// Note: DMs are auto-encrypted, so callers must pass the recipient_id and
/// device id of the peer; the helper builds a ciphertext-shaped payload
/// that satisfies the server-side gate (#591).
async fn post_message(
    ws: &mut WsStream,
    conversation_id: &str,
    tag: &str,
    recipient_user_id: &str,
) -> String {
    let canonical = common::dummy_ciphertext(&format!("{tag}_canonical"));
    let recipient_ct = common::dummy_ciphertext(&format!("{tag}_recipient"));
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": conversation_id,
        "content": canonical,
        "recipient_device_contents": {
            recipient_user_id.to_string(): { "0": recipient_ct },
        },
    });
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send_message frame failed");
    let evt = wait_for_event(ws, &["message_sent", "error"]).await;
    assert_eq!(
        evt["type"], "message_sent",
        "expected message_sent, got: {evt}"
    );
    evt["message_id"]
        .as_str()
        .expect("missing message_id in message_sent")
        .to_string()
}

/// Send a `send_message` with a `reply_to_id`.  Returns `Ok(message_id)` on
/// `message_sent`, `Err(error_text)` on `error`.
async fn post_reply_raw(
    ws: &mut WsStream,
    conversation_id: &str,
    tag: &str,
    reply_to_id: &str,
    recipient_user_id: &str,
) -> Result<String, String> {
    let canonical = common::dummy_ciphertext(&format!("{tag}_canonical"));
    let recipient_ct = common::dummy_ciphertext(&format!("{tag}_recipient"));
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": conversation_id,
        "content": canonical,
        "reply_to_id": reply_to_id,
        "recipient_device_contents": {
            recipient_user_id.to_string(): { "0": recipient_ct },
        },
    });
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send_message frame failed");
    let evt = wait_for_event(ws, &["message_sent", "error"]).await;
    match evt["type"].as_str() {
        Some("message_sent") => Ok(evt["message_id"].as_str().unwrap().to_string()),
        Some("error") => Err(evt["message"].as_str().unwrap_or("").to_string()),
        other => panic!("unexpected event type: {other:?}"),
    }
}

/// #519 -- replying to a message in another conversation is rejected.
///
/// We use the WS path because that is the only ingress for sending messages
/// in this codebase (there is no REST `POST /api/messages`).  The expectation
/// from the plan was a 404 over REST; the WS-equivalent is an `error` frame
/// with the "reply_to message not found" text emitted by the
/// `RowNotFound`-translation in `ws/message_service.rs`.
#[tokio::test]
async fn reply_to_message_in_other_conversation_is_rejected() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "scope_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "scope_bob").await;
    let (carol_token, carol_id, carol_name) =
        common::register_and_login(&client, &base, "scope_carol").await;
    let bob_id_for_post = bob_id.clone();
    let carol_id_for_post = carol_id.clone();

    // alice <-> bob and alice <-> carol are two disjoint DM conversations.
    let conv_ab =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;
    let conv_ac = common::make_contacts(
        &client,
        &base,
        &alice_token,
        &carol_token,
        &carol_id,
        &carol_name,
    )
    .await;
    assert_ne!(conv_ab, conv_ac, "expected two distinct conversations");

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    drain_pending(&mut alice_ws).await;

    // Alice posts a message in conv_ab.
    let parent_id =
        post_message(&mut alice_ws, &conv_ab, "scope_parent_ab", &bob_id_for_post).await;

    // Drain any echoes/new_message frames before the next interaction.
    drain_pending(&mut alice_ws).await;

    // Now Alice tries to reply *in conv_ac* to that conv_ab message.
    let result = post_reply_raw(
        &mut alice_ws,
        &conv_ac,
        "scope_leak",
        &parent_id,
        &carol_id_for_post,
    )
    .await;

    let err = result.expect_err("cross-conversation reply must be rejected");
    assert!(
        err.to_lowercase().contains("reply_to"),
        "error should mention reply_to, got: {err}"
    );

    // Verify nothing with the leaking marker landed in conv_ac. We check the
    // server didn't persist *any* row containing the canonical leak ciphertext
    // we tried to post.
    let leaking_marker = common::dummy_ciphertext("scope_leak_canonical");
    let resp = client
        .get(format!("{base}/api/messages/{conv_ac}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let messages: Value = resp.json().await.unwrap();
    let arr = messages.as_array().expect("messages must be an array");
    assert!(
        arr.iter().all(|m| m["content"] != leaking_marker),
        "rejected reply must not be persisted: {arr:?}"
    );

    let _ = alice_ws.close(None).await;
}

/// #519 -- thread replies query is scoped to the parent's conversation and
/// access-controlled to its members.
#[tokio::test]
async fn thread_replies_does_not_return_cross_conversation_replies() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "thr_alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "thr_bob").await;
    let (carol_token, _carol_id, _carol_name) =
        common::register_and_login(&client, &base, "thr_carol").await;

    let conv_ab =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    // Alice posts a parent message in conv_ab and Bob replies to it.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    let parent_id = post_message(&mut alice_ws, &conv_ab, "thr_parent", &bob_id).await;
    drain_pending(&mut bob_ws).await;
    // Bob is replying back in the same DM, so the recipient is Alice.
    let _reply_id = post_reply_raw(&mut bob_ws, &conv_ab, "thr_reply", &parent_id, &alice_id)
        .await
        .expect("in-conversation reply should succeed");

    drain_pending(&mut alice_ws).await;
    drain_pending(&mut bob_ws).await;

    // Carol is not a member of conv_ab; her token must not be able to view
    // thread replies (401/403 -- the route uses AppError::unauthorized).
    let resp = client
        .get(format!("{base}/api/messages/{parent_id}/replies"))
        .header("Authorization", format!("Bearer {carol_token}"))
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    assert!(
        status == 401 || status == 403,
        "non-member must be rejected (got {status})"
    );

    // Alice (a member) sees exactly one reply, the in-conversation one.
    let resp = client
        .get(format!("{base}/api/messages/{parent_id}/replies"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let replies = body.as_array().expect("replies must be an array");
    assert_eq!(replies.len(), 1, "expected exactly one reply: {replies:?}");
    let expected_content = common::dummy_ciphertext("thr_reply_canonical");
    assert_eq!(replies[0]["content"], expected_content);
    assert_eq!(replies[0]["conversation_id"].as_str().unwrap(), conv_ab);

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}
