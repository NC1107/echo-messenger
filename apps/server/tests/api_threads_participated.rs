//! Integration test for `GET /api/threads/participated` (#449 last sub-item).
//!
//! The endpoint aggregates every thread the authenticated user has either
//! authored a reply in, or been mentioned in via a reply. Each row returns
//! enough metadata to render the "Threads" sidebar entry without follow-up
//! fetches: the parent's preview, the reply count, an unread approximation,
//! and the most-recent reply's author + timestamp.
//!
//! This test uses a plaintext group so the WS send-path does not require the
//! ciphertext gate (#591). The thread aggregation query is content-agnostic —
//! a real encrypted conversation would exercise the exact same SQL with
//! ciphertext blobs in `parent_preview`, which the client decrypts.

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

/// Send a plaintext group message; returns the new message id.
async fn send_group_message(ws: &mut WsStream, group_id: &str, content: &str) -> String {
    let send = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": content,
    });
    ws.send(Message::Text(send.to_string().into()))
        .await
        .expect("send_message failed");
    let evt = common::recv_until_event(ws, &["message_sent", "error"]).await;
    assert_eq!(
        evt["type"], "message_sent",
        "expected message_sent, got: {evt}"
    );
    evt["message_id"]
        .as_str()
        .expect("missing message_id")
        .to_string()
}

/// Send a plaintext group reply to `reply_to_id`; returns the new message id.
async fn send_group_reply(
    ws: &mut WsStream,
    group_id: &str,
    content: &str,
    reply_to_id: &str,
) -> String {
    let send = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": content,
        "reply_to_id": reply_to_id,
    });
    ws.send(Message::Text(send.to_string().into()))
        .await
        .expect("send_reply failed");
    let evt = common::recv_until_event(ws, &["message_sent", "error"]).await;
    assert_eq!(
        evt["type"], "message_sent",
        "expected message_sent, got: {evt}"
    );
    evt["message_id"]
        .as_str()
        .expect("missing message_id")
        .to_string()
}

async fn list_participated(client: &Client, base: &str, token: &str) -> Vec<Value> {
    let resp = client
        .get(format!("{base}/api/threads/participated"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .expect("GET /api/threads/participated");
    assert_eq!(
        resp.status().as_u16(),
        200,
        "participated threads endpoint should 200"
    );
    resp.json::<Vec<Value>>().await.expect("threads JSON")
}

/// Alice posts a parent message in the group; Bob replies. Alice should see
/// the thread on `/api/threads/participated` (she authored the parent — note:
/// "participated" here is reply-author OR mentioned, NOT parent-author, so we
/// confirm Bob also sees the thread because he authored the reply) and the
/// reply should appear unread for Alice until she marks the conversation read.
#[tokio::test]
async fn participated_threads_lists_threads_user_replied_in_with_unread_count() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, alice_name) =
        common::register_and_login(&client, &base, "thr_p_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "thr_p_bob").await;

    let group = common::create_plaintext_group(&client, &base, &alice_token, "Threadland").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;

    // Connect both members over WS.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_ws).await;

    // Alice posts the parent; Bob replies to it.
    let parent_id = send_group_message(&mut alice_ws, &group, "anyone seen the build?").await;
    common::drain_pending(&mut bob_ws).await;

    let _reply_id =
        send_group_reply(&mut bob_ws, &group, "yeah it just went green", &parent_id).await;
    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_ws).await;

    // Bob authored the reply → his /threads/participated should include
    // the parent. (Endpoint contract: "user replied in OR was mentioned".)
    let bob_threads = list_participated(&client, &base, &bob_token).await;
    assert_eq!(
        bob_threads.len(),
        1,
        "bob should see exactly one participated thread: {bob_threads:?}"
    );
    let bob_row = &bob_threads[0];
    assert_eq!(bob_row["parent_message_id"].as_str().unwrap(), parent_id);
    assert_eq!(bob_row["conversation_id"].as_str().unwrap(), group);
    assert_eq!(bob_row["reply_count"].as_i64().unwrap(), 1);
    assert_eq!(
        bob_row["parent_preview"].as_str().unwrap(),
        "anyone seen the build?"
    );
    // Bob authored the reply, so his unread count for it is 0.
    assert_eq!(
        bob_row["unread_reply_count"].as_i64().unwrap(),
        0,
        "self-authored replies shouldn't count as unread"
    );

    // Alice has not replied or been mentioned, so the endpoint does NOT
    // surface this thread for her — by design, the sidebar entry only
    // shows threads the user has participated in. (Parent-author has the
    // message in their normal conversation history.)
    let alice_threads = list_participated(&client, &base, &alice_token).await;
    assert!(
        alice_threads.is_empty(),
        "parent-author alone shouldn't see /threads/participated: {alice_threads:?}"
    );

    // Now Alice replies too. After that, Alice's /threads/participated
    // should surface the thread, and the unread count for her should be
    // 1 (Bob's reply is newer than the read receipt epoch fallback).
    let _alice_reply = send_group_reply(&mut alice_ws, &group, "nice", &parent_id).await;
    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_ws).await;

    let alice_threads = list_participated(&client, &base, &alice_token).await;
    assert_eq!(
        alice_threads.len(),
        1,
        "alice should now see the thread after replying: {alice_threads:?}"
    );
    let row = &alice_threads[0];
    assert_eq!(row["parent_message_id"].as_str().unwrap(), parent_id);
    assert_eq!(row["reply_count"].as_i64().unwrap(), 2);
    assert_eq!(
        row["unread_reply_count"].as_i64().unwrap(),
        1,
        "Bob's reply should count as 1 unread (Alice's own reply is not unread)"
    );
    assert_eq!(
        row["last_reply_sender_username"].as_str().unwrap(),
        alice_name, // Alice replied last
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}
