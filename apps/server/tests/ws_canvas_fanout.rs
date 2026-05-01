//! Integration test for canvas draw event fanout over WebSocket.
//!
//! Verifies that when one group member sends a `canvas_event` WS frame, all
//! other connected members (not just the sender) receive the relayed event.
//! Covers the bug reported in #432 where events were silently dropped.

mod common;

use futures_util::SinkExt;
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

/// Read frames until a `canvas_event` arrives or timeout (5 s).
async fn recv_canvas_event(ws: &mut WsStream) -> Value {
    common::recv_until_event(ws, &["canvas_event"]).await
}

/// Set up a group with three members.  Returns:
/// `(group_id, channel_id, alice_token, alice_id, bob_token, charlie_token)`
async fn setup_three_member_group(
    client: &Client,
    base: &str,
) -> (String, String, String, String, String, String) {
    let (alice_token, alice_id, _) = common::register_and_login(client, base, "cvs_alice").await;
    let (bob_token, bob_id, _) = common::register_and_login(client, base, "cvs_bob").await;
    let (charlie_token, charlie_id, _) =
        common::register_and_login(client, base, "cvs_charlie").await;

    let group_id = common::create_group(client, base, &alice_token, "CanvasFanoutGroup").await;
    common::add_member_to_group(client, base, &alice_token, &group_id, &bob_id).await;
    common::add_member_to_group(client, base, &alice_token, &group_id, &charlie_id).await;

    // Fetch the default "lounge" voice channel created with the group.
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let channels: Vec<Value> = resp.json().await.unwrap();
    let channel_id = channels
        .iter()
        .find(|c| c["name"] == "lounge")
        .expect("default lounge channel must exist")["id"]
        .as_str()
        .unwrap()
        .to_string();

    (
        group_id,
        channel_id,
        alice_token,
        alice_id,
        bob_token,
        charlie_token,
    )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Alice draws a stroke; Bob and Charlie (the other two connected members)
/// each receive a `canvas_event` with the correct channel, kind, and payload.
#[tokio::test]
async fn canvas_stroke_fans_out_to_all_members() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (_, channel_id, alice_token, _, bob_token, charlie_token) =
        setup_three_member_group(&client, &base).await;

    // Connect all three members.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let charlie_ticket = common::get_ws_ticket(&client, &base, &charlie_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;
    let mut charlie_ws = connect_ws(&base, &charlie_ticket).await;

    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_ws).await;
    common::drain_pending(&mut charlie_ws).await;

    // Alice sends a canvas stroke event.
    let stroke_payload = serde_json::json!({
        "id": "stroke-abc",
        "color": "#FF0000",
        "width": 3.0,
        "points": [{"x": 0.1, "y": 0.2}, {"x": 0.3, "y": 0.4}],
        "kind": "pen",
    });
    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "canvas_event",
                "channel_id": channel_id,
                "kind": "stroke",
                "payload": stroke_payload,
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("alice canvas send failed");

    // Bob receives the relayed event.
    let bob_event = recv_canvas_event(&mut bob_ws).await;
    assert_eq!(bob_event["type"], "canvas_event", "bob: wrong event type");
    assert_eq!(
        bob_event["channel_id"],
        channel_id.as_str(),
        "bob: wrong channel_id"
    );
    assert_eq!(bob_event["kind"], "stroke", "bob: wrong kind");
    assert_eq!(
        bob_event["payload"]["id"], "stroke-abc",
        "bob: wrong stroke id"
    );

    // Charlie receives the relayed event.
    let charlie_event = recv_canvas_event(&mut charlie_ws).await;
    assert_eq!(
        charlie_event["type"], "canvas_event",
        "charlie: wrong event type"
    );
    assert_eq!(
        charlie_event["channel_id"],
        channel_id.as_str(),
        "charlie: wrong channel_id"
    );
    assert_eq!(charlie_event["kind"], "stroke", "charlie: wrong kind");
    assert_eq!(
        charlie_event["payload"]["id"], "stroke-abc",
        "charlie: wrong stroke id"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
    let _ = charlie_ws.close(None).await;
}

/// Alice draws; the relayed event carries Alice's user_id in `from_user_id`.
#[tokio::test]
async fn canvas_event_carries_sender_user_id() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (_, channel_id, alice_token, alice_id, bob_token, _) =
        setup_three_member_group(&client, &base).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_ws).await;

    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "canvas_event",
                "channel_id": channel_id,
                "kind": "clear",
                "payload": {},
            })
            .to_string()
            .into(),
        ))
        .await
        .unwrap();

    let event = recv_canvas_event(&mut bob_ws).await;
    assert_eq!(
        event["from_user_id"],
        alice_id.as_str(),
        "relayed event must identify the sender"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}

/// Avatar move events (ephemeral) are relayed to peers but never persisted.
#[tokio::test]
async fn canvas_avatar_move_relayed_but_not_persisted() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (group_id, channel_id, alice_token, _, bob_token, _) =
        setup_three_member_group(&client, &base).await;

    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;

    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    let mut bob_ws = connect_ws(&base, &bob_ticket).await;

    common::drain_pending(&mut alice_ws).await;
    common::drain_pending(&mut bob_ws).await;

    // Alice sends an avatar_move event.
    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "canvas_event",
                "channel_id": channel_id,
                "kind": "avatar_move",
                "payload": {"user_id": "alice", "x": 0.5, "y": 0.5},
            })
            .to_string()
            .into(),
        ))
        .await
        .unwrap();

    // Bob receives it.
    let event = recv_canvas_event(&mut bob_ws).await;
    assert_eq!(event["kind"], "avatar_move");

    // Canvas REST endpoint should still return empty arrays (avatar_move is ephemeral).
    let canvas: Value = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        canvas["drawing_data"],
        serde_json::json!([]),
        "avatar_move must not be persisted"
    );

    let _ = alice_ws.close(None).await;
    let _ = bob_ws.close(None).await;
}
