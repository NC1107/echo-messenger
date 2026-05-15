//! Integration tests for the `last_reply_snippet` field added in #423.
//!
//! The field surfaces the most-recent reply's content under the parent
//! message in the main conversation view (Slack-style inline preview).
//! It is populated only by `get_messages` (history) -- the WS real-time
//! path keeps using `reply_count` increments and does not carry the
//! snippet on `message_reply_added`.
//!
//! Invariants exercised here:
//!   * 0 replies          -> snippet is null
//!   * 1 reply            -> snippet equals that reply's canonical content
//!   * many replies       -> snippet equals the LATEST by created_at
//!   * server-side cap    -> snippet length never exceeds 80 chars
//!
//! DMs are encrypted, so the canonical `messages.content` is always the
//! base64-wrapped ciphertext envelope `dummy_ciphertext` produces. The
//! snippet is sliced from that same string, so assertions compare
//! against the ciphertext (not a human-readable body).

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

/// Post a `send_message` whose canonical body is `dummy_ciphertext(tag)`,
/// optionally as a reply to `reply_to_id`. Returns `(message_id, canonical)`
/// so callers can assert the snippet equals the canonical content of the
/// most-recent reply.
async fn post(
    ws: &mut WsStream,
    conversation_id: &str,
    tag: &str,
    recipient_user_id: &str,
    reply_to_id: Option<&str>,
) -> (String, String) {
    let canonical = common::dummy_ciphertext(&format!("{tag}_canonical"));
    let recipient_ct = common::dummy_ciphertext(&format!("{tag}_recipient"));
    let mut frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": conversation_id,
        "content": canonical,
        "recipient_device_contents": {
            recipient_user_id.to_string(): { "0": recipient_ct },
        },
    });
    if let Some(parent) = reply_to_id {
        frame
            .as_object_mut()
            .unwrap()
            .insert("reply_to_id".into(), serde_json::json!(parent));
    }
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send_message failed");
    let evt = common::recv_until_event(ws, &["message_sent", "error"]).await;
    assert_eq!(
        evt["type"], "message_sent",
        "expected message_sent, got: {evt}"
    );
    let id = evt["message_id"]
        .as_str()
        .expect("missing message_id")
        .to_string();
    (id, canonical)
}

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

fn truncate_80(s: &str) -> String {
    // Match Postgres `LEFT(content, 80)` (chars, not bytes). Our test
    // payloads are ASCII so chars == bytes either way.
    s.chars().take(80).collect()
}

#[tokio::test]
async fn last_reply_snippet_zero_one_many() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "snip_alice").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "snip_bob").await;

    let conv =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // Parent with zero replies: snippet should be null.
    let (parent_id, _) = post(&mut alice_ws, &conv, "parent", &bob_id, None).await;
    common::drain_pending(&mut alice_ws).await;

    let listing = fetch_messages(&client, &base, &alice_token, &conv).await;
    let parent_row = listing
        .iter()
        .find(|m| m["id"].as_str() == Some(&parent_id))
        .expect("parent row");
    assert_eq!(parent_row["reply_count"].as_i64(), Some(0));
    assert!(
        parent_row["last_reply_snippet"].is_null(),
        "zero-reply parent must have null snippet, got: {}",
        parent_row["last_reply_snippet"]
    );

    // One reply: snippet should equal the reply's canonical content
    // (truncated to 80 chars by the server).
    let (_r1, r1_canonical) = post(&mut alice_ws, &conv, "r1", &bob_id, Some(&parent_id)).await;
    common::drain_pending(&mut alice_ws).await;

    let listing = fetch_messages(&client, &base, &alice_token, &conv).await;
    let parent_row = listing
        .iter()
        .find(|m| m["id"].as_str() == Some(&parent_id))
        .expect("parent row");
    assert_eq!(parent_row["reply_count"].as_i64(), Some(1));
    assert_eq!(
        parent_row["last_reply_snippet"].as_str(),
        Some(truncate_80(&r1_canonical).as_str()),
        "one-reply snippet must equal that reply's truncated canonical content"
    );

    // Many replies: snippet should be the LATEST one by created_at.
    let (_r2, _) = post(&mut alice_ws, &conv, "r2", &bob_id, Some(&parent_id)).await;
    common::drain_pending(&mut alice_ws).await;
    let (_r3, r3_canonical) =
        post(&mut alice_ws, &conv, "r3_latest", &bob_id, Some(&parent_id)).await;
    common::drain_pending(&mut alice_ws).await;

    let listing = fetch_messages(&client, &base, &alice_token, &conv).await;
    let parent_row = listing
        .iter()
        .find(|m| m["id"].as_str() == Some(&parent_id))
        .expect("parent row");
    assert_eq!(parent_row["reply_count"].as_i64(), Some(3));
    assert_eq!(
        parent_row["last_reply_snippet"].as_str(),
        Some(truncate_80(&r3_canonical).as_str()),
        "many-reply snippet must equal the chronologically latest reply's truncated content"
    );

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn last_reply_snippet_truncates_to_80_chars() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "snip_long_a").await;
    let (bob_token, bob_id, bob_name) =
        common::register_and_login(&client, &base, "snip_long_b").await;

    let conv =
        common::make_contacts(&client, &base, &alice_token, &bob_token, &bob_id, &bob_name).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let (parent_id, _) = post(&mut alice_ws, &conv, "parent", &bob_id, None).await;
    common::drain_pending(&mut alice_ws).await;

    // Use a long tag so dummy_ciphertext produces a base64 payload well
    // over 80 chars. The 200-char tag below yields a >250-char base64
    // body; the server must clamp the wire snippet to 80.
    let long_tag = "x".repeat(200);
    let (_, long_canonical) =
        post(&mut alice_ws, &conv, &long_tag, &bob_id, Some(&parent_id)).await;
    common::drain_pending(&mut alice_ws).await;
    assert!(
        long_canonical.chars().count() > 80,
        "test setup: payload should be >80 chars to exercise the cap"
    );

    let listing = fetch_messages(&client, &base, &alice_token, &conv).await;
    let parent_row = listing
        .iter()
        .find(|m| m["id"].as_str() == Some(&parent_id))
        .expect("parent row");
    let snippet = parent_row["last_reply_snippet"]
        .as_str()
        .expect("snippet must be present for non-empty thread");
    assert!(
        snippet.chars().count() <= 80,
        "snippet must be clamped server-side; got {} chars",
        snippet.chars().count()
    );
    assert_eq!(
        snippet,
        truncate_80(&long_canonical),
        "snippet must be the first 80 chars of the canonical reply body"
    );

    let _ = alice_ws.close(None).await;
}
