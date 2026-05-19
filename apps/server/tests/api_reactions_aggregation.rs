//! Integration tests for reaction aggregation on the history wire (#832, gap 3).
//!
//! The reaction wire shape is anchored by the LATERAL `json_agg` in
//! `db::messages::get_messages`: every `(user_id, emoji)` row of the
//! `reactions` table that joins to a message becomes one entry in the
//! returned `reactions` array on the history JSON. Clients aggregate
//! counts client-side by counting entries with the same `emoji`.
//!
//! Invariants exercised:
//!   * two users react with the same emoji -> two array entries -> count == 2
//!   * same user reacts twice with same emoji -> one array entry
//!     (ON CONFLICT idempotent; #832 gap 3 explicitly calls this out)
//!   * different emoji per user -> both tracked separately
//!   * removing a reaction drops it from the array
//!   * a soft-deleted message hides its reactions from history (the
//!     `deleted_at IS NULL` filter on the parent join means the LEFT
//!     JOIN never materialises the message row at all)

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

/// Send a plaintext group message and return the `message_id`.
async fn send_plain_message(ws: &mut WsStream, group_id: &str, content: &str) -> String {
    let frame = serde_json::json!({
        "type": "send_message",
        "conversation_id": group_id,
        "content": content,
    });
    ws.send(Message::Text(frame.to_string().into()))
        .await
        .expect("send_message failed");
    let evt = common::recv_until_event(ws, &["message_sent", "error"]).await;
    assert_eq!(evt["type"], "message_sent", "got: {evt}");
    evt["message_id"].as_str().unwrap().to_string()
}

async fn add_reaction(
    client: &Client,
    base: &str,
    token: &str,
    message_id: &str,
    emoji: &str,
) -> u16 {
    client
        .post(format!("{base}/api/messages/{message_id}/reactions"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "emoji": emoji }))
        .send()
        .await
        .unwrap()
        .status()
        .as_u16()
}

async fn remove_reaction(
    client: &Client,
    base: &str,
    token: &str,
    message_id: &str,
    emoji: &str,
) -> u16 {
    client
        .delete(format!(
            "{base}/api/messages/{message_id}/reactions/{emoji}"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap()
        .status()
        .as_u16()
}

/// Return the `reactions` array on the parent message from
/// `GET /api/messages/{conv}`. Panics if the message is missing.
async fn fetch_reactions(
    client: &Client,
    base: &str,
    token: &str,
    conv: &str,
    message_id: &str,
) -> Vec<Value> {
    let resp = client
        .get(format!("{base}/api/messages/{conv}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let list: Vec<Value> = resp.json().await.unwrap();
    let row = list
        .into_iter()
        .find(|m| m["id"].as_str() == Some(message_id))
        .unwrap_or_else(|| panic!("message {message_id} not in history"));
    row["reactions"].as_array().cloned().unwrap_or_default()
}

fn count_emoji(reactions: &[Value], emoji: &str) -> usize {
    reactions
        .iter()
        .filter(|r| r["emoji"].as_str() == Some(emoji))
        .count()
}

#[tokio::test]
async fn two_users_same_emoji_aggregate_to_count_two() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "rxa_alice").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "rxa_bob").await;

    let group = common::create_plaintext_group(&client, &base, &alice_token, "TwoUsersGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let msg_id = send_plain_message(&mut alice_ws, &group, "react to me").await;
    common::drain_pending(&mut alice_ws).await;

    assert_eq!(
        add_reaction(&client, &base, &alice_token, &msg_id, "👍").await,
        201
    );
    assert_eq!(
        add_reaction(&client, &base, &bob_token, &msg_id, "👍").await,
        201
    );

    let reactions = fetch_reactions(&client, &base, &alice_token, &group, &msg_id).await;
    assert_eq!(
        count_emoji(&reactions, "👍"),
        2,
        "two users reacting with the same emoji must aggregate to 2: {reactions:?}"
    );

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn same_user_same_emoji_is_idempotent() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "rxa_idem").await;

    let group =
        common::create_plaintext_group(&client, &base, &alice_token, "IdempotentGroup").await;
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let msg_id = send_plain_message(&mut alice_ws, &group, "double tap").await;
    common::drain_pending(&mut alice_ws).await;

    // Two POSTs with the same emoji from the same user must yield one row.
    assert_eq!(
        add_reaction(&client, &base, &alice_token, &msg_id, "🎉").await,
        201
    );
    assert_eq!(
        add_reaction(&client, &base, &alice_token, &msg_id, "🎉").await,
        201,
        "second POST is still a 201 (ON CONFLICT DO UPDATE)"
    );

    let reactions = fetch_reactions(&client, &base, &alice_token, &group, &msg_id).await;
    assert_eq!(
        count_emoji(&reactions, "🎉"),
        1,
        "same user + same emoji must collapse to a single entry: {reactions:?}"
    );

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn different_emoji_per_user_tracked_separately() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) =
        common::register_and_login(&client, &base, "rxa_diff_a").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "rxa_diff_b").await;

    let group =
        common::create_plaintext_group(&client, &base, &alice_token, "DiffEmojiGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let msg_id = send_plain_message(&mut alice_ws, &group, "split vote").await;
    common::drain_pending(&mut alice_ws).await;

    assert_eq!(
        add_reaction(&client, &base, &alice_token, &msg_id, "👍").await,
        201
    );
    assert_eq!(
        add_reaction(&client, &base, &bob_token, &msg_id, "👎").await,
        201
    );

    let reactions = fetch_reactions(&client, &base, &alice_token, &group, &msg_id).await;
    assert_eq!(count_emoji(&reactions, "👍"), 1);
    assert_eq!(count_emoji(&reactions, "👎"), 1);
    assert_eq!(reactions.len(), 2);

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn remove_reaction_drops_it_from_history() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "rxa_rm_a").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "rxa_rm_b").await;

    let group = common::create_plaintext_group(&client, &base, &alice_token, "RemoveGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let msg_id = send_plain_message(&mut alice_ws, &group, "remove me").await;
    common::drain_pending(&mut alice_ws).await;

    assert_eq!(
        add_reaction(&client, &base, &alice_token, &msg_id, "💯").await,
        201
    );
    assert_eq!(
        add_reaction(&client, &base, &bob_token, &msg_id, "💯").await,
        201
    );
    assert_eq!(
        count_emoji(
            &fetch_reactions(&client, &base, &alice_token, &group, &msg_id).await,
            "💯"
        ),
        2
    );

    // Bob removes his reaction; only alice's remains.
    assert_eq!(
        remove_reaction(&client, &base, &bob_token, &msg_id, "💯").await,
        200
    );
    let after = fetch_reactions(&client, &base, &alice_token, &group, &msg_id).await;
    assert_eq!(
        count_emoji(&after, "💯"),
        1,
        "removing one user's reaction must drop exactly one entry: {after:?}"
    );

    let _ = alice_ws.close(None).await;
}

#[tokio::test]
async fn soft_deleted_message_drops_its_reactions_from_history() {
    // `get_messages` filters `m.deleted_at IS NULL`, which short-circuits the
    // LATERAL reaction aggregate for soft-deleted parents.  Once Alice deletes
    // her own message, the row disappears from history and so does the
    // reaction count -- the underlying `reactions` table rows still exist
    // (no CASCADE on soft-delete) but the wire never surfaces them again.
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _) = common::register_and_login(&client, &base, "rxa_sd_a").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "rxa_sd_b").await;

    let group = common::create_plaintext_group(&client, &base, &alice_token, "SoftDelGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group, &bob_id).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    let msg_id = send_plain_message(&mut alice_ws, &group, "going away").await;
    common::drain_pending(&mut alice_ws).await;

    assert_eq!(
        add_reaction(&client, &base, &bob_token, &msg_id, "✅").await,
        201
    );

    // Alice (the sender) soft-deletes the message.
    let del = client
        .delete(format!("{base}/api/messages/{msg_id}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    // DELETE /api/messages/:id returns 204 No Content on success.
    assert_eq!(del.status().as_u16(), 204);

    // History should no longer include the message at all.
    let resp = client
        .get(format!("{base}/api/messages/{group}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    let list: Vec<Value> = resp.json().await.unwrap();
    assert!(
        !list
            .iter()
            .any(|m| m["id"].as_str() == Some(msg_id.as_str())),
        "soft-deleted message must vanish from history (and so do its reactions)"
    );

    let _ = alice_ws.close(None).await;
}
