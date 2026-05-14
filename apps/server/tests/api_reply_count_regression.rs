//! Regression tests for the reply-count migration in `search_messages` and
//! `get_thread_replies` (#834 finding 8). The audit migrated both queries
//! from a LATERAL `COUNT(*)` correlated subquery (O(N*M)) to a single
//! GROUP-BY subquery joined once (O(N+M)). The risk of the migration is a
//! shift in result shape -- LEFT JOIN semantics on the aggregating
//! subquery must still produce 0 for messages with no replies, must count
//! the right number for messages with one, and must scale correctly for
//! messages with many.
//!
//! Both queries surface `reply_count` to the wire:
//!   * `search_messages` -> `GET /api/conversations/{id}/search?q=...`
//!   * `get_thread_replies` -> `GET /api/messages/{id}/replies`
//!
//! Hitting both endpoints exercises the migrated SQL through the same
//! deserialisation path the client uses, so any GROUP-BY divergence shows
//! up as a wrong `reply_count` value in the response JSON.

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

/// Post a `send_message` and return the `message_id` from the
/// `message_sent` confirmation. Reuses the same wire shape as
/// `api_messages_reply_scope::post_message`.
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

/// Post a reply to `reply_to_id` and return the resulting `message_id`.
async fn post_reply(
    ws: &mut WsStream,
    conversation_id: &str,
    tag: &str,
    reply_to_id: &str,
    recipient_user_id: &str,
) -> String {
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

/// Pull the canonical message history for `conversation_id` via the REST
/// route used by `search_messages`'s sister listing call. The list returns
/// `reply_count` per message via the same `MessageWithSender` shape, so we
/// use it to cross-check the search/thread responses (which carry the
/// migrated query).
async fn fetch_messages(client: &Client, base: &str, token: &str, conv_id: &str) -> Vec<Value> {
    let resp = client
        .get(format!("{base}/api/messages/{conv_id}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .expect("GET messages");
    assert_eq!(resp.status().as_u16(), 200);
    resp.json::<Vec<Value>>().await.expect("messages JSON")
}

/// `get_thread_replies` must return 0 / 1 / many reply_counts correctly
/// after the GROUP-BY migration. We post one parent, then incrementally
/// reply to it and read back the thread; the parent's reply_count in the
/// canonical message list must keep pace.
#[tokio::test]
async fn thread_replies_reply_count_zero_one_many() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "rc_alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "rc_bob").await;

    let conv =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // Parent with zero replies.
    let parent_id = post_message(&mut alice_ws, &conv, "rc_parent", &bob_id).await;
    common::drain_pending(&mut alice_ws).await;

    // get_thread_replies for parent should be empty.
    let resp = client
        .get(format!("{base}/api/messages/{parent_id}/replies"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let replies: Vec<Value> = resp.json().await.unwrap();
    assert_eq!(replies.len(), 0, "zero-reply parent must return []");

    // Canonical message listing should report reply_count == 0 for parent.
    let listing = fetch_messages(&client, &base, &alice_token, &conv).await;
    let parent_row = listing
        .iter()
        .find(|m| m["id"].as_str() == Some(&parent_id))
        .expect("parent row");
    assert_eq!(parent_row["reply_count"].as_i64(), Some(0));

    // One reply.
    let _r1 = post_reply(&mut alice_ws, &conv, "rc_r1", &parent_id, &bob_id).await;
    common::drain_pending(&mut alice_ws).await;

    let resp = client
        .get(format!("{base}/api/messages/{parent_id}/replies"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    let replies: Vec<Value> = resp.json().await.unwrap();
    assert_eq!(replies.len(), 1, "one-reply parent must return one row");
    // Each reply is itself a message and -- on the migrated query -- must
    // surface a reply_count of 0 (it has no children yet).
    assert_eq!(replies[0]["reply_count"].as_i64(), Some(0));

    let listing = fetch_messages(&client, &base, &alice_token, &conv).await;
    let parent_row = listing
        .iter()
        .find(|m| m["id"].as_str() == Some(&parent_id))
        .expect("parent row");
    assert_eq!(parent_row["reply_count"].as_i64(), Some(1));

    // Many replies (5 total).
    for i in 2..=5 {
        let _ = post_reply(
            &mut alice_ws,
            &conv,
            &format!("rc_r{i}"),
            &parent_id,
            &bob_id,
        )
        .await;
        common::drain_pending(&mut alice_ws).await;
    }

    let resp = client
        .get(format!("{base}/api/messages/{parent_id}/replies"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    let replies: Vec<Value> = resp.json().await.unwrap();
    assert_eq!(replies.len(), 5, "five-reply parent must return five rows");
    for r in &replies {
        // None of the leaf replies have replies of their own.
        assert_eq!(r["reply_count"].as_i64(), Some(0));
    }

    let listing = fetch_messages(&client, &base, &alice_token, &conv).await;
    let parent_row = listing
        .iter()
        .find(|m| m["id"].as_str() == Some(&parent_id))
        .expect("parent row");
    assert_eq!(parent_row["reply_count"].as_i64(), Some(5));

    let _ = alice_ws.close(None).await;
    let _ = alice_id; // silence unused
}

/// `search_messages` runs the same GROUP-BY-joined `reply_count` after the
/// migration. With the encrypted-DM gate (#591) the search index sees only
/// ciphertext, so we can't reliably get a search hit on a plaintext
/// keyword. Instead we exercise the route to confirm it returns 200 with
/// the post-migration query (a wrong query shape would 500 here, not
/// 200), which is the gate that catches a structural mistake in the
/// migrated SQL.
#[tokio::test]
async fn search_messages_still_returns_200_after_migration() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "rc_srch_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "rc_srch_bob").await;
    let conv =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let parent_id = post_message(&mut alice_ws, &conv, "srch_parent", &bob_id).await;
    common::drain_pending(&mut alice_ws).await;
    let _ = post_reply(&mut alice_ws, &conv, "srch_reply", &parent_id, &bob_id).await;
    common::drain_pending(&mut alice_ws).await;

    let resp = client
        .get(format!("{base}/api/conversations/{conv}/search?q=anything"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "migrated search query must still answer 200"
    );
    let body: Vec<Value> = resp.json().await.unwrap();
    // Any returned row must carry a numeric reply_count (post-migration
    // shape) rather than null / missing.
    for row in &body {
        assert!(
            row.get("reply_count").and_then(|v| v.as_i64()).is_some(),
            "search row missing reply_count after migration: {row}"
        );
    }

    let _ = alice_ws.close(None).await;
}
