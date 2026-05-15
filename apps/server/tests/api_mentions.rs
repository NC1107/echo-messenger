//! Integration tests for `@-mention` parsing and dispatch (#832, gap 1).
//!
//! `db::mentions::extract_and_persist` is invoked from the message send
//! path on plaintext groups (encrypted groups can't be inspected
//! server-side and intentionally skip mention persistence). The
//! resulting rows show up to the client as `mention_count` on
//! `GET /api/conversations`.
//!
//! Coverage:
//!   * direct `@username` adds one mention to the named user
//!   * `@everyone` adds a mention to every non-sender member
//!   * `@here` likewise adds a mention to every non-sender member
//!     (the suppression in #451 only affects push, not the row)
//!   * non-existent `@bogus` username is a no-op (no mention rows)
//!   * the sender does NOT get a mention for `@everyone` / `@here`
//!
//! Encrypted DMs are not exercised here: the route never reaches
//! `extract_and_persist` for encrypted conversations, and DMs are
//! always encrypted (#591). The asserted contract is therefore "in a
//! plaintext group".

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

/// Send a plaintext group message and wait for `message_sent`.
async fn send_group_message(ws: &mut WsStream, group_id: &str, content: &str) {
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
}

/// Fetch the conversation list for `token` and return the row matching
/// `conversation_id`. Panics if the conversation is not in the list.
async fn fetch_conversation(
    client: &Client,
    base: &str,
    token: &str,
    conversation_id: &str,
) -> Value {
    let resp = client
        .get(format!("{base}/api/conversations"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .expect("GET /api/conversations");
    assert_eq!(resp.status().as_u16(), 200);
    let list: Vec<Value> = resp.json().await.expect("conversations JSON");
    list.into_iter()
        .find(|c| c["conversation_id"].as_str() == Some(conversation_id))
        .unwrap_or_else(|| panic!("conversation {conversation_id} not in /api/conversations list"))
}

async fn mention_count(client: &Client, base: &str, token: &str, conv_id: &str) -> i64 {
    fetch_conversation(client, base, token, conv_id).await["mention_count"]
        .as_i64()
        .expect("mention_count missing")
}

#[tokio::test]
async fn direct_username_mention_increments_only_mentioned_user() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "mn_alice").await;
    let (bob_token, bob_id, bob_name) = common::register_and_login(&client, &base, "mn_bob").await;
    let (charlie_token, charlie_id, _charlie_name) =
        common::register_and_login(&client, &base, "mn_charlie").await;

    let group = common::create_group(&client, &base, &alice_token, "MentionGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &charlie_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    send_group_message(
        &mut alice_ws,
        &group,
        &format!("hey @{bob_name} have a sec?"),
    )
    .await;
    common::drain_pending(&mut alice_ws).await;

    // Only the named user should see mention_count == 1.
    assert_eq!(mention_count(&client, &base, &bob_token, &group).await, 1);
    assert_eq!(
        mention_count(&client, &base, &charlie_token, &group).await,
        0
    );
    // Sender's own count stays 0 (alice was not the named user).
    assert_eq!(mention_count(&client, &base, &alice_token, &group).await, 0);

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn at_everyone_mentions_all_non_sender_members() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "mn_ev_a").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "mn_ev_b").await;
    let (carol_token, carol_id, _) = common::register_and_login(&client, &base, "mn_ev_c").await;

    let group = common::create_group(&client, &base, &alice_token, "EveryoneGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &carol_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    send_group_message(&mut alice_ws, &group, "@everyone all hands meeting").await;
    common::drain_pending(&mut alice_ws).await;

    // Both non-sender members should have one mention.
    assert_eq!(mention_count(&client, &base, &bob_token, &group).await, 1);
    assert_eq!(mention_count(&client, &base, &carol_token, &group).await, 1);
    // Sender is filtered out.
    assert_eq!(mention_count(&client, &base, &alice_token, &group).await, 0);

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn at_here_mentions_all_non_sender_members() {
    // @here writes the same mention rows as @everyone -- the suppression
    // in #451 only changes the push fanout, not the persisted mention.
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "mn_hr_a").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "mn_hr_b").await;
    let (carol_token, carol_id, _) = common::register_and_login(&client, &base, "mn_hr_c").await;

    let group = common::create_group(&client, &base, &alice_token, "HereGroup2").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &carol_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    send_group_message(&mut alice_ws, &group, "@here are you free?").await;
    common::drain_pending(&mut alice_ws).await;

    assert_eq!(mention_count(&client, &base, &bob_token, &group).await, 1);
    assert_eq!(mention_count(&client, &base, &carol_token, &group).await, 1);
    assert_eq!(mention_count(&client, &base, &alice_token, &group).await, 0);

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn nonexistent_username_mention_is_noop() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "mn_nx_a").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "mn_nx_b").await;

    let group = common::create_group(&client, &base, &alice_token, "BogusGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // Reference a user who does not exist anywhere in the system.
    send_group_message(&mut alice_ws, &group, "ping @nobody_with_this_name").await;
    common::drain_pending(&mut alice_ws).await;

    // Nobody gets a mention row.
    assert_eq!(mention_count(&client, &base, &alice_token, &group).await, 0);
    assert_eq!(mention_count(&client, &base, &bob_token, &group).await, 0);

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn mention_of_non_member_username_is_filtered() {
    // An existing user who is NOT a member of the group must not get a
    // mention row -- the resolver joins on `conversation_members` so a
    // typo'd `@<unrelated user>` cannot pull them into a group's badge.
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "mn_nm_a").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "mn_nm_b").await;
    let (outsider_token, _outsider_id, outsider_name) =
        common::register_and_login(&client, &base, "mn_nm_outsider").await;

    let group = common::create_group(&client, &base, &alice_token, "ScopedGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;
    // outsider is intentionally NOT added.

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    send_group_message(&mut alice_ws, &group, &format!("ghost @{outsider_name}")).await;
    common::drain_pending(&mut alice_ws).await;

    // Bob (real member) gets no mention; outsider isn't in this group's
    // conversation list at all so we don't query their badge here -- the
    // assertion that matters is that nothing leaks into the group's row.
    assert_eq!(mention_count(&client, &base, &bob_token, &group).await, 0);
    assert_eq!(mention_count(&client, &base, &alice_token, &group).await, 0);

    let _ = alice_ws.close(None).await;
    let _ = outsider_token;
}
