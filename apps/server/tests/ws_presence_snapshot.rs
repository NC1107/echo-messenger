//! Integration test for the presence_list snapshot on WS connect (#436).
//!
//! Verifies that when a third user connects via WebSocket, the server
//! immediately sends a `presence_list` event listing the contacts of that user
//! who are already online — so stale offline indicators are not shown after
//! a reconnect.

mod common;

use futures_util::StreamExt;
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

/// Connect two contacts, then connect a third and assert it receives a
/// `presence_list` snapshot whose `users` array includes the two who are
/// already online.
#[tokio::test]
async fn presence_snapshot_on_connect_includes_online_contacts() {
    let base = common::spawn_server().await;
    let client = Client::new();

    // Register alice, bob, charlie.
    let (alice_token, alice_id, _alice_name) =
        common::register_and_login(&client, &base, "snap_alice").await;
    let (bob_token, bob_id, _bob_name) =
        common::register_and_login(&client, &base, "snap_bob").await;
    let (charlie_token, charlie_id, charlie_name) =
        common::register_and_login(&client, &base, "snap_charlie").await;

    // Make alice <-> charlie contacts and bob <-> charlie contacts so charlie
    // should see both in the snapshot.
    make_contact_pair(
        &client,
        &base,
        &alice_token,
        &charlie_token,
        &charlie_id,
        &charlie_name,
    )
    .await;
    make_contact_pair(
        &client,
        &base,
        &bob_token,
        &charlie_token,
        &charlie_id,
        &charlie_name,
    )
    .await;

    let ws_url = base.replace("http://", "ws://");

    // Connect alice and bob first — they are already online.
    let alice_ticket = common::get_ws_ticket(&client, &base, &alice_token).await;
    let (alice_ws, _) =
        tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={alice_ticket}"))
            .await
            .expect("alice WS connect failed");
    let (_alice_write, alice_read) = alice_ws.split();

    let bob_ticket = common::get_ws_ticket(&client, &base, &bob_token).await;
    let (bob_ws, _) = tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={bob_ticket}"))
        .await
        .expect("bob WS connect failed");
    let (_bob_write, bob_read) = bob_ws.split();

    // Give the server a moment to register alice and bob in the hub.
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Now charlie connects and should receive a presence_list snapshot.
    let charlie_ticket = common::get_ws_ticket(&client, &base, &charlie_token).await;
    let (charlie_ws, _) =
        tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={charlie_ticket}"))
            .await
            .expect("charlie WS connect failed");
    let (_charlie_write, mut charlie_read) = charlie_ws.split();

    // Read frames from charlie until we get a presence_list (max 3 seconds).
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut snapshot: Option<Value> = None;
    loop {
        let next = tokio::time::timeout_at(deadline, charlie_read.next()).await;
        match next {
            Ok(Some(Ok(Message::Text(text)))) => {
                if let Ok(v) = serde_json::from_str::<Value>(&text)
                    && v["type"].as_str() == Some("presence_list")
                {
                    snapshot = Some(v);
                    break;
                }
            }
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(e))) => panic!("WS error reading charlie: {e}"),
            Ok(None) => panic!("charlie WS stream ended"),
            Err(_) => break, // timeout
        }
    }

    let snapshot = snapshot.expect("charlie should have received a presence_list snapshot");
    let users = snapshot["users"]
        .as_array()
        .expect("users must be an array");

    let online_ids: Vec<&str> = users.iter().filter_map(|u| u["user_id"].as_str()).collect();

    assert!(
        online_ids.contains(&alice_id.as_str()),
        "alice should be in charlie's presence_list snapshot; got: {online_ids:?}"
    );
    assert!(
        online_ids.contains(&bob_id.as_str()),
        "bob should be in charlie's presence_list snapshot; got: {online_ids:?}"
    );

    // charlie's own id must NOT appear (they are the one connecting).
    assert!(
        !online_ids.contains(&charlie_id.as_str()),
        "charlie must not appear in their own snapshot; got: {online_ids:?}"
    );

    // Suppress unused variable warnings -- alice and bob reads are held open
    // to keep the connections alive for the duration of the test.
    drop(alice_read);
    drop(bob_read);
}

/// Connect a user who has no online contacts — snapshot should still arrive
/// but with an empty users array.
#[tokio::test]
async fn presence_snapshot_empty_when_no_contacts_online() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (dave_token, _, _) = common::register_and_login(&client, &base, "snap_dave").await;

    let ws_url = base.replace("http://", "ws://");
    let ticket = common::get_ws_ticket(&client, &base, &dave_token).await;
    let (dave_ws, _) = tokio_tungstenite::connect_async(format!("{ws_url}/ws?ticket={ticket}"))
        .await
        .expect("dave WS connect failed");
    let (_write, mut read) = dave_ws.split();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut got_snapshot = false;
    loop {
        let next = tokio::time::timeout_at(deadline, read.next()).await;
        match next {
            Ok(Some(Ok(Message::Text(text)))) => {
                if let Ok(v) = serde_json::from_str::<Value>(&text)
                    && v["type"].as_str() == Some("presence_list")
                {
                    let users = v["users"].as_array().expect("users must be array");
                    assert!(
                        users.is_empty(),
                        "snapshot should be empty when no contacts are online"
                    );
                    got_snapshot = true;
                    break;
                }
            }
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(e))) => panic!("WS error: {e}"),
            Ok(None) => panic!("WS stream ended"),
            Err(_) => break,
        }
    }

    assert!(
        got_snapshot,
        "user with no online contacts should still receive an empty presence_list snapshot"
    );
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

/// Make user A and user B mutual contacts (A requests, B accepts).
/// `user_b_name` is used for A's request; `charlie_id` is B's user id.
async fn make_contact_pair(
    client: &Client,
    base: &str,
    token_a: &str,
    token_b: &str,
    _user_b_id: &str,
    username_b: &str,
) {
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {token_a}"))
        .json(&serde_json::json!({ "username": username_b }))
        .send()
        .await
        .unwrap();
    let status = resp.status().as_u16();
    assert_eq!(status, 201, "contact request should 201");
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().unwrap().to_string();

    let resp = client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {token_b}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200, "accept should 200");
}
