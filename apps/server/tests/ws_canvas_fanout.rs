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

/// A late joiner — connecting AFTER strokes have been drawn — can fetch the
/// persisted canvas via the REST endpoint and see every prior stroke and
/// image. This is the primary "voice canvas is global / one source of truth"
/// guarantee that user testing on 2026-05-27 required.
///
/// The flow: Alice draws (WS `stroke` + `image_add`), then Charlie — who was
/// not connected when Alice drew — registers, joins the group, and GETs the
/// canvas. The response must contain both the stroke and the image.
#[tokio::test]
async fn late_joiner_sees_persisted_strokes_and_images() {
    let base = common::spawn_server().await;
    let client = Client::new();

    // Alice creates the group and the lounge.
    let (alice_token, alice_id, _) =
        common::register_and_login(&client, &base, "cvs_late_alice").await;
    let group_id =
        common::create_group(&client, &base, &alice_token, "LateJoinerCanvasGroup").await;

    // Pre-seed a media row Alice owns so the `image_add` ownership gate
    // (#1332) accepts the pinned image. The url must be `/api/media/<uuid>`.
    let media_id = uuid::Uuid::new_v4();
    let pool = common::test_pool().await;
    echo_server::db::media::create_media(
        &pool,
        media_id,
        uuid::Uuid::parse_str(&alice_id).unwrap(),
        "photo.png",
        "image/png",
        1024,
        None,
        None,
        None,
    )
    .await
    .unwrap();
    let media_url = format!("/api/media/{media_id}");

    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    let channels: Vec<Value> = resp.json().await.unwrap();
    let channel_id = channels
        .iter()
        .find(|c| c["name"] == "lounge")
        .expect("default lounge channel must exist")["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Alice connects and draws.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // Helper: send one canvas event over Alice's WS and flush. We intentionally
    // flush + small sleep between sends because the existing single-event
    // fanout tests in this file (and unit tests on the server) cover the
    // "race-y back-to-back writes" path; what THIS test guards is the
    // persist-then-late-joiner-load contract, not concurrent-write semantics.
    async fn send_event(ws: &mut WsStream, channel_id: &str, kind: &str, payload: Value) {
        use futures_util::SinkExt;
        use futures_util::StreamExt;
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
        .unwrap();
        ws.flush().await.unwrap();
        // Drain any back-pressure response frames (errors, fanout echoes
        // when other members are connected, etc.) so the next send isn't
        // sitting behind an unread frame. This also surfaces server-side
        // error frames that would otherwise be invisible — they get
        // printed via the assert below so test failures show WHY.
        while let Ok(Some(Ok(msg))) =
            tokio::time::timeout(std::time::Duration::from_millis(150), ws.next()).await
        {
            if let Message::Text(t) = msg
                && t.contains("\"type\":\"error\"")
            {
                panic!("server returned error frame for {kind}: {t}");
            }
        }
    }

    // Drop a freehand stroke (highlighter — a new kind the server must
    // JSONB-passthrough without rejection).
    send_event(
        &mut alice_ws,
        &channel_id,
        "stroke",
        serde_json::json!({
            "id": "stroke-late-1",
            "color": "#00FFAA",
            "width": 4.0,
            "points": [{"x": 0.1, "y": 0.1}, {"x": 0.4, "y": 0.5}],
            "kind": "highlighter",
        }),
    )
    .await;

    // Drop a text label (kind="text" — new tool set).
    send_event(
        &mut alice_ws,
        &channel_id,
        "stroke",
        serde_json::json!({
            "id": "stroke-late-2",
            "color": "#FFCC00",
            "width": 18.0,
            "points": [{"x": 0.6, "y": 0.7}],
            "kind": "text",
            "text": "hello late joiner",
        }),
    )
    .await;

    // Drop a rect shape (kind="rect" — new tool set).
    send_event(
        &mut alice_ws,
        &channel_id,
        "stroke",
        serde_json::json!({
            "id": "stroke-late-3",
            "color": "#FF00FF",
            "width": 2.0,
            "points": [{"x": 0.2, "y": 0.2}, {"x": 0.5, "y": 0.5}],
            "kind": "rect",
        }),
    )
    .await;

    // Add an image.
    send_event(
        &mut alice_ws,
        &channel_id,
        "image_add",
        serde_json::json!({
            "id": "img-late-1",
            "url": media_url,
            "x": 0.3,
            "y": 0.4,
            "width": 0.2,
            "height": 0.2,
        }),
    )
    .await;

    // Allow the server's async DB writes to land before Alice disconnects.
    // The handler awaits the DB call before broadcasting, so once the next
    // GET round-trip resolves, the rows are committed. We poll the REST
    // endpoint until the rows appear instead of sleeping a fixed duration.
    // The wait is bounded so a server regression (e.g. one stroke kind
    // being rejected) fails the test loudly instead of hanging the suite.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let alice_canvas: Value = loop {
        let v: Value = client
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
        let strokes = v["drawing_data"].as_array().cloned().unwrap_or_default();
        let images = v["images_data"].as_array().cloned().unwrap_or_default();
        if strokes.len() == 3 && images.len() == 1 {
            break v;
        }
        if std::time::Instant::now() > deadline {
            panic!(
                "timed out waiting for persisted canvas state: strokes={}, images={}, body={v}",
                strokes.len(),
                images.len()
            );
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    };
    assert_eq!(alice_canvas["drawing_data"].as_array().unwrap().len(), 3);
    assert_eq!(alice_canvas["images_data"].as_array().unwrap().len(), 1);

    // Alice disconnects — the canvas should still be in the DB.
    let _ = alice_ws.close(None).await;

    // Charlie is a brand-new user joining the group AFTER all the drawing
    // happened. He never had a WS connection during the draw events, so the
    // ONLY way he sees the strokes is via the REST snapshot.
    let (charlie_token, charlie_id, _) =
        common::register_and_login(&client, &base, "cvs_late_charlie").await;
    common::add_member_to_group(&client, &base, &alice_token, &group_id, &charlie_id).await;

    let resp = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {charlie_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "late joiner must be able to GET the canvas after being added"
    );
    let body: Value = resp.json().await.unwrap();

    let strokes = body["drawing_data"].as_array().expect("drawing_data array");
    assert_eq!(strokes.len(), 3, "all three strokes must be persisted");

    let ids: Vec<&str> = strokes.iter().filter_map(|s| s["id"].as_str()).collect();
    assert!(ids.contains(&"stroke-late-1"));
    assert!(ids.contains(&"stroke-late-2"));
    assert!(ids.contains(&"stroke-late-3"));

    // The new stroke kinds (highlighter, text, rect) must round-trip
    // verbatim — the server is JSONB passthrough and must NOT reject them.
    let kinds: Vec<&str> = strokes.iter().filter_map(|s| s["kind"].as_str()).collect();
    assert!(kinds.contains(&"highlighter"));
    assert!(kinds.contains(&"text"));
    assert!(kinds.contains(&"rect"));

    // Text label payload survives round-trip (verifies opaque JSONB column).
    let text_stroke = strokes.iter().find(|s| s["id"] == "stroke-late-2").unwrap();
    assert_eq!(text_stroke["text"], "hello late joiner");

    let images = body["images_data"].as_array().expect("images_data array");
    assert_eq!(images.len(), 1, "image must be persisted for late joiners");
    assert_eq!(images[0]["id"], "img-late-1");
    assert_eq!(images[0]["url"], media_url);
}

/// Sending a canvas event to a text channel (not a voice channel) returns an
/// error frame and does NOT fan out the event.  Exercises the channel-kind guard
/// added by audit fix 1.
#[tokio::test]
async fn canvas_event_to_text_channel_returns_error() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _, _) =
        common::register_and_login(&client, &base, "cvs_textguard_alice").await;
    let group_id = common::create_group(&client, &base, &alice_token, "CanvasTextGuardGroup").await;

    // Find the default "general" text channel.
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let channels: Vec<Value> = resp.json().await.unwrap();
    let text_channel_id = channels
        .iter()
        .find(|c| c["kind"] == "text")
        .expect("default text channel must exist")["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Connect Alice.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let mut alice_ws = connect_ws(&base, &alice_ticket).await;
    common::drain_pending(&mut alice_ws).await;

    // Send a canvas_event to the text channel.
    alice_ws
        .send(Message::Text(
            serde_json::json!({
                "type": "canvas_event",
                "channel_id": text_channel_id,
                "kind": "stroke",
                "payload": {"id": "s1"},
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("alice canvas send failed");

    // The server must reply with an error frame.
    let error_frame = common::recv_until_event(&mut alice_ws, &["error"]).await;
    assert!(
        error_frame["message"]
            .as_str()
            .unwrap_or("")
            .contains("voice"),
        "error message should mention voice channels, got: {error_frame}"
    );

    let _ = alice_ws.close(None).await;
}
