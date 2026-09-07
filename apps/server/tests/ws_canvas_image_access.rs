//! Integration test for canvas `image_add` media-ownership enforcement
//! (VL-16 / #1332).
//!
//! `image_add` used to accept any url shaped like `/api/media/<uuid>` without
//! checking the sender could actually access that media. A member could pin
//! another user's private upload onto the shared board by replaying its id.
//! The server now runs `can_user_access_media` before persisting/broadcasting.

mod common;

use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_ws(base: &str, ticket: &str) -> WsStream {
    let ws_base = base.replace("http://", "ws://");
    let (ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");
    ws
}

/// Create a group and return `(group_id, lounge_channel_id)`.
async fn group_with_lounge(client: &Client, base: &str, token: &str) -> (String, String) {
    let group_id = common::create_group(client, base, token, "ImgAccessGroup").await;
    let resp = client
        .get(format!("{base}/api/groups/{group_id}/channels"))
        .header("Authorization", format!("Bearer {token}"))
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
    (group_id, channel_id)
}

async fn send_image_add(ws: &mut WsStream, channel_id: &str, image_id: &str, url: &str) {
    ws.send(Message::Text(
        serde_json::json!({
            "type": "canvas_event",
            "channel_id": channel_id,
            "kind": "image_add",
            "payload": {
                "id": image_id,
                "url": url,
                "x": 100.0,
                "y": 100.0,
                "width": 200.0,
                "height": 200.0,
            },
        })
        .to_string()
        .into(),
    ))
    .await
    .unwrap();
    ws.flush().await.unwrap();
}

/// Read all frames for ~400ms, returning whether an `error` frame arrived.
async fn saw_error_frame(ws: &mut WsStream) -> bool {
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(400);
    while std::time::Instant::now() < deadline {
        match tokio::time::timeout(std::time::Duration::from_millis(150), ws.next()).await {
            Ok(Some(Ok(Message::Text(t)))) if t.contains("\"type\":\"error\"") => return true,
            Ok(Some(Ok(_))) => {}
            _ => {}
        }
    }
    false
}

async fn canvas_image_count(
    client: &Client,
    base: &str,
    group_id: &str,
    channel_id: &str,
    token: &str,
) -> usize {
    let body: Value = client
        .get(format!(
            "{base}/api/groups/{group_id}/channels/{channel_id}/canvas"
        ))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    body["images_data"].as_array().map(|a| a.len()).unwrap_or(0)
}

#[tokio::test]
async fn image_add_accepts_owned_media() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = common::test_pool().await;

    let (token, user_id, _) = common::register_and_login(&client, &base, "imgacc_owner").await;
    let (group_id, channel_id) = group_with_lounge(&client, &base, &token).await;

    // A media row the user owns.
    let media_id = Uuid::new_v4();
    echo_server::db::media::create_media(
        &pool,
        media_id,
        Uuid::parse_str(&user_id).unwrap(),
        "owned.png",
        "image/png",
        1024,
        None,
        None,
        None,
    )
    .await
    .unwrap();

    let ticket = common::get_ws_ticket(&client, &base, &token).await;
    let mut ws = connect_ws(&base, &ticket).await;
    common::drain_pending(&mut ws).await;

    send_image_add(
        &mut ws,
        &channel_id,
        "img-ok",
        &format!("/api/media/{media_id}"),
    )
    .await;

    // Poll until the image is persisted (bounded).
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if canvas_image_count(&client, &base, &group_id, &channel_id, &token).await == 1 {
            break;
        }
        if std::time::Instant::now() > deadline {
            panic!("owned-media image_add was not persisted");
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }

    let _ = ws.close(None).await;
}

#[tokio::test]
async fn image_add_rejects_inaccessible_media() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let pool = common::test_pool().await;

    // Eve owns a private media file in her own (separate) context.
    let (_eve_token, eve_id, _) = common::register_and_login(&client, &base, "imgacc_eve").await;
    let private_media = Uuid::new_v4();
    echo_server::db::media::create_media(
        &pool,
        private_media,
        Uuid::parse_str(&eve_id).unwrap(),
        "private.png",
        "image/png",
        1024,
        None,
        None,
        None,
    )
    .await
    .unwrap();

    // Mallory is a member of the lounge but does NOT own / cannot access Eve's media.
    let (token, _id, _) = common::register_and_login(&client, &base, "imgacc_mallory").await;
    let (group_id, channel_id) = group_with_lounge(&client, &base, &token).await;

    let ticket = common::get_ws_ticket(&client, &base, &token).await;
    let mut ws = connect_ws(&base, &ticket).await;
    common::drain_pending(&mut ws).await;

    send_image_add(
        &mut ws,
        &channel_id,
        "img-stolen",
        &format!("/api/media/{private_media}"),
    )
    .await;

    assert!(
        saw_error_frame(&mut ws).await,
        "server should reject image_add for inaccessible media"
    );

    // And it must NOT have persisted.
    assert_eq!(
        canvas_image_count(&client, &base, &group_id, &channel_id, &token).await,
        0,
        "inaccessible media must not be pinned to the board"
    );

    let _ = ws.close(None).await;
}
