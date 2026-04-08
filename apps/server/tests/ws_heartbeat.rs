//! Integration test for the WebSocket application-level heartbeat.
//!
//! Verifies that the server sends `{"type":"heartbeat"}` JSON text frames
//! on an idle connection, which keeps browser clients alive (browser WS APIs
//! don't surface protocol-level Ping frames).

mod common;

use futures_util::StreamExt;
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

/// Connect via WebSocket and verify at least one heartbeat arrives within 35s.
#[tokio::test]
async fn heartbeat_arrives_on_idle_connection() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let name = common::unique_username("hb");
    common::register(&client, &base, &name, "password123").await;
    let (token, _) = common::login(&client, &base, &name, "password123").await;
    let ticket = common::get_ws_ticket(&client, &base, &token).await;

    let ws_url = base.replace("http://", "ws://");
    let (ws_stream, _) = tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={ticket}"))
        .await
        .expect("WS connect failed");

    let (_write, mut read) = ws_stream.split();

    let mut heartbeat_received = false;

    // Wait up to 35 seconds for a heartbeat (server sends every 30s).
    let deadline = tokio::time::Instant::now() + Duration::from_secs(35);

    loop {
        let msg = tokio::time::timeout_at(deadline, read.next()).await;
        match msg {
            Ok(Some(Ok(Message::Text(text)))) => {
                if let Ok(json) = serde_json::from_str::<Value>(&text)
                    && json.get("type").and_then(|t| t.as_str()) == Some("heartbeat")
                {
                    heartbeat_received = true;
                    break;
                }
            }
            Ok(Some(Ok(Message::Ping(_)))) => {
                // Protocol ping -- expected but we need the text heartbeat too
                continue;
            }
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(e))) => panic!("WS error: {e}"),
            Ok(None) => panic!("WS stream ended before heartbeat"),
            Err(_) => break, // Timeout
        }
    }

    assert!(
        heartbeat_received,
        "Expected at least one {{\"type\":\"heartbeat\"}} within 35 seconds"
    );
}
