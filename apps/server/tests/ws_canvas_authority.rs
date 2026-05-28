//! Integration tests for per-lounge canvas authority.
//!
//! Verifies the decisions in `docs/voice-lounge/03-multi-device.md`:
//!
//! 1. First canvas event from any device implicitly claims authority. A
//!    later event from a *different* device for the same user is silently
//!    dropped (no error frame back) and not relayed to peers.
//! 2. `canvas_authority_claim` from a different device within the 1-second
//!    grace window is rejected; after the grace window it succeeds and the
//!    server broadcasts `canvas_authority_changed`.
//! 3. Leaving the voice channel clears authority — the next event from any
//!    device reclaims it cleanly.

mod common;

use std::time::Duration;

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

/// Look up the default "lounge" voice channel created with every group.
async fn lounge_channel_id(client: &Client, base: &str, token: &str, group_id: &str) -> String {
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();
    let channels: Vec<Value> = resp.json().await.unwrap();
    channels
        .iter()
        .find(|c| c["name"] == "lounge")
        .expect("default lounge channel must exist")["id"]
        .as_str()
        .unwrap()
        .to_string()
}

async fn send_canvas_event(ws: &mut WsStream, channel_id: &str, kind: &str, payload: Value) {
    ws.send(Message::Text(
        serde_json::json!({
            "type": "canvas_event",
            "channel_id": channel_id,
            "kind": kind,
            "payload": payload,
        })
        .to_string()
        .into(),
    ))
    .await
    .expect("canvas WS send failed");
}

/// Wait up to 750ms for *any* `canvas_event` to arrive on `ws`. Returns the
/// frame if one is seen; returns `None` if the stream stays quiet — used to
/// assert silent drops (no relay, no error). 750ms is generous compared to
/// the round-trip + DB cost of an event that *would* fan out (~5-20ms).
async fn try_recv_canvas_event(ws: &mut WsStream) -> Option<Value> {
    use futures_util::StreamExt;
    let deadline = tokio::time::Instant::now() + Duration::from_millis(750);
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(remaining, ws.next()).await {
            Ok(Some(Ok(Message::Text(t)))) => {
                if let Ok(v) = serde_json::from_str::<Value>(&t)
                    && v["type"] == "canvas_event"
                {
                    return Some(v);
                }
            }
            Ok(Some(Ok(_other))) => continue,
            _ => return None,
        }
    }
    None
}

/// Two-member group where Alice connects with TWO devices. Returns
/// `(channel_id, alice_token, alice_id, alice_ws_dev1, alice_ws_dev2, bob_ws)`.
async fn setup_two_device_lounge(
    client: &Client,
    base: &str,
) -> (String, String, WsStream, WsStream, WsStream) {
    let (alice_token, alice_id, _) = common::register_and_login(client, base, "auth_alice").await;
    let (bob_token, bob_id, _) = common::register_and_login(client, base, "auth_bob").await;

    let group_id = common::create_group(client, base, &alice_token, "AuthorityGroup").await;
    common::add_member_to_group(client, base, &alice_token, &group_id, &bob_id).await;
    let channel_id = lounge_channel_id(client, base, &alice_token, &group_id).await;

    // Alice has device 1 and device 2; Bob has device 1.
    let alice_ticket_1 = common::get_ws_ticket_for_device(client, base, &alice_token, 1).await;
    let alice_ticket_2 = common::get_ws_ticket_for_device(client, base, &alice_token, 2).await;
    let bob_ticket = common::get_ws_ticket_for_device(client, base, &bob_token, 1).await;

    let mut alice_ws_1 = connect_ws(base, &alice_ticket_1).await;
    let mut alice_ws_2 = connect_ws(base, &alice_ticket_2).await;
    let mut bob_ws = connect_ws(base, &bob_ticket).await;

    common::drain_pending(&mut alice_ws_1).await;
    common::drain_pending(&mut alice_ws_2).await;
    common::drain_pending(&mut bob_ws).await;

    (channel_id, alice_id, alice_ws_1, alice_ws_2, bob_ws)
}

/// First event from device A claims authority implicitly; an event from
/// device B for the same user is silently dropped (Bob never sees it).
#[tokio::test]
async fn second_device_event_is_silently_dropped() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (channel_id, _alice_id, mut a1, mut a2, mut bob) =
        setup_two_device_lounge(&client, &base).await;

    // Device 1 draws — implicit claim.
    send_canvas_event(
        &mut a1,
        &channel_id,
        "stroke",
        serde_json::json!({
            "id": "s-d1",
            "color": "#FF0000",
            "width": 2.0,
            "points": [{"x": 0.1, "y": 0.2}, {"x": 0.3, "y": 0.4}],
            "kind": "pen",
        }),
    )
    .await;

    // Bob receives the stroke from device 1.
    let bob_event = try_recv_canvas_event(&mut bob)
        .await
        .expect("Bob must receive device 1's stroke");
    assert_eq!(bob_event["payload"]["id"], "s-d1");

    // Device 2 attempts to draw — must be silently dropped.
    send_canvas_event(
        &mut a2,
        &channel_id,
        "stroke",
        serde_json::json!({
            "id": "s-d2",
            "color": "#00FF00",
            "width": 2.0,
            "points": [{"x": 0.5, "y": 0.5}, {"x": 0.6, "y": 0.6}],
            "kind": "pen",
        }),
    )
    .await;

    // Bob must NOT see device 2's stroke.
    let dropped = try_recv_canvas_event(&mut bob).await;
    assert!(
        dropped.is_none(),
        "device 2's stroke must be silently dropped, got {dropped:?}"
    );

    let _ = a1.close(None).await;
    let _ = a2.close(None).await;
    let _ = bob.close(None).await;
}

/// `canvas_authority_claim` from device B within the 1-second grace window
/// fails (Bob still sees device 1's strokes after the attempt); after the
/// grace window the claim succeeds and the broadcast switches who can write.
#[tokio::test]
async fn authority_claim_respects_grace_window() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (channel_id, alice_id, mut a1, mut a2, mut bob) =
        setup_two_device_lounge(&client, &base).await;

    // Device 1 claims implicitly.
    send_canvas_event(
        &mut a1,
        &channel_id,
        "avatar_move",
        serde_json::json!({"user_id": alice_id.to_string(), "x": 0.5, "y": 0.5}),
    )
    .await;
    let _ = try_recv_canvas_event(&mut bob)
        .await
        .expect("bob sees device 1's avatar move");

    // Device 2 tries to claim immediately — grace window must reject.
    send_canvas_event(
        &mut a2,
        &channel_id,
        "canvas_authority_claim",
        serde_json::json!({}),
    )
    .await;

    // Device 2 draws — still must be dropped because authority didn't change.
    send_canvas_event(
        &mut a2,
        &channel_id,
        "avatar_move",
        serde_json::json!({"user_id": alice_id.to_string(), "x": 0.6, "y": 0.6}),
    )
    .await;
    let in_grace = try_recv_canvas_event(&mut bob).await;
    assert!(
        in_grace.is_none(),
        "device 2 must still be silenced inside grace window: {in_grace:?}"
    );

    // Wait past the 1s grace window and re-claim.
    tokio::time::sleep(Duration::from_millis(1100)).await;
    send_canvas_event(
        &mut a2,
        &channel_id,
        "canvas_authority_claim",
        serde_json::json!({}),
    )
    .await;

    // Device 2 now draws — must fan out to Bob.
    send_canvas_event(
        &mut a2,
        &channel_id,
        "avatar_move",
        serde_json::json!({"user_id": alice_id.to_string(), "x": 0.7, "y": 0.7}),
    )
    .await;

    let after_grace = try_recv_canvas_event(&mut bob)
        .await
        .expect("bob must see device 2's avatar move after handoff");
    assert!((after_grace["payload"]["x"].as_f64().unwrap() - 0.7).abs() < 1e-6);

    let _ = a1.close(None).await;
    let _ = a2.close(None).await;
    let _ = bob.close(None).await;
}

/// Leaving the lounge clears the user's canvas authority, so the next
/// device to draw reclaims fresh — including the device that was previously
/// silenced.
#[tokio::test]
async fn authority_clears_on_voice_leave() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, alice_id, _) =
        common::register_and_login(&client, &base, "auth_leave_alice").await;
    let (bob_token, bob_id, _) = common::register_and_login(&client, &base, "auth_leave_bob").await;

    let group_id = common::create_group(&client, &base, &alice_token, "AuthorityLeaveGroup").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &bob_id).await;
    let channel_id = lounge_channel_id(&client, &base, &alice_token, &group_id).await;

    // Alice joins the voice channel so leave_voice_channel actually has
    // something to remove (REST leave path).
    let resp = client
        .post(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/voice/join"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "voice join failed: {:?}", resp);

    let alice_ticket_1 = common::get_ws_ticket_for_device(&client, &base, &alice_token, 1).await;
    let alice_ticket_2 = common::get_ws_ticket_for_device(&client, &base, &alice_token, 2).await;
    let bob_ticket = common::get_ws_ticket_for_device(&client, &base, &bob_token, 1).await;

    let mut a1 = connect_ws(&base, &alice_ticket_1).await;
    let mut a2 = connect_ws(&base, &alice_ticket_2).await;
    let mut bob = connect_ws(&base, &bob_ticket).await;
    common::drain_pending(&mut a1).await;
    common::drain_pending(&mut a2).await;
    common::drain_pending(&mut bob).await;

    // Device 1 claims implicitly.
    send_canvas_event(
        &mut a1,
        &channel_id,
        "avatar_move",
        serde_json::json!({"user_id": alice_id.to_string(), "x": 0.5, "y": 0.5}),
    )
    .await;
    let _ = try_recv_canvas_event(&mut bob)
        .await
        .expect("bob sees device 1's avatar move");

    // Device 2 still silenced.
    send_canvas_event(
        &mut a2,
        &channel_id,
        "avatar_move",
        serde_json::json!({"user_id": alice_id.to_string(), "x": 0.6, "y": 0.6}),
    )
    .await;
    assert!(try_recv_canvas_event(&mut bob).await.is_none());

    // Alice leaves the voice channel via REST — clear_on_leave fires.
    let resp = client
        .post(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/voice/leave"
        ))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    // Drain the voice_session_left event that fans out.
    common::drain_pending(&mut bob).await;

    // Now device 2 draws — must implicitly reclaim and fan out.
    send_canvas_event(
        &mut a2,
        &channel_id,
        "avatar_move",
        serde_json::json!({"user_id": alice_id.to_string(), "x": 0.8, "y": 0.8}),
    )
    .await;
    let reclaimed = try_recv_canvas_event(&mut bob)
        .await
        .expect("bob must see device 2's avatar move after voice-leave clears authority");
    assert!((reclaimed["payload"]["x"].as_f64().unwrap() - 0.8).abs() < 1e-6);

    let _ = a1.close(None).await;
    let _ = a2.close(None).await;
    let _ = bob.close(None).await;
}
