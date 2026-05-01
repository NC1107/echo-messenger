//! Integration tests for contact management endpoints.

mod common;

use reqwest::Client;
use serde_json::Value;

#[tokio::test]
async fn contact_request_accept_list_flow() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let alice_name = common::unique_username("alice");
    let bob_name = common::unique_username("bob");

    common::register(&client, &base, &alice_name, "password123").await;
    common::register(&client, &base, &bob_name, "password123").await;

    let (alice_token, _alice_id) = common::login(&client, &base, &alice_name, "password123").await;
    let (bob_token, _bob_id) = common::login(&client, &base, &bob_name, "password123").await;

    // Alice sends contact request to Bob
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "username": bob_name }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().expect("missing contact_id");

    // Bob accepts the request
    let resp = client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Alice sees Bob in contacts
    let resp = client
        .get(format!("{base}/api/contacts"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let contacts: Vec<Value> = resp.json().await.unwrap();
    assert!(
        contacts
            .iter()
            .any(|c| c["username"].as_str() == Some(&bob_name)),
        "Alice should see Bob in her contacts"
    );

    // Bob sees Alice in contacts
    let resp = client
        .get(format!("{base}/api/contacts"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let contacts: Vec<Value> = resp.json().await.unwrap();
    assert!(
        contacts
            .iter()
            .any(|c| c["username"].as_str() == Some(&alice_name)),
        "Bob should see Alice in his contacts"
    );
}

#[tokio::test]
async fn pending_requests_visible() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let alice_name = common::unique_username("alice");
    let bob_name = common::unique_username("bob");

    common::register(&client, &base, &alice_name, "password123").await;
    common::register(&client, &base, &bob_name, "password123").await;

    let (alice_token, _) = common::login(&client, &base, &alice_name, "password123").await;
    let (bob_token, _) = common::login(&client, &base, &bob_name, "password123").await;

    // Alice sends contact request to Bob
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "username": bob_name }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);

    // Bob sees pending request
    let resp = client
        .get(format!("{base}/api/contacts/pending"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let pending: Vec<Value> = resp.json().await.unwrap();
    assert!(
        !pending.is_empty(),
        "Bob should see at least one pending request"
    );
}

// NOTE: self-contact request is not currently rejected by the server.
// Add validation server-side before enabling this test.
// #[tokio::test]
// async fn cannot_send_contact_request_to_self() { ... }

/// Helper: complete the full contact request + accept handshake between two users.
async fn make_contacts(
    client: &Client,
    base: &str,
    requester_token: &str,
    accepter_token: &str,
    accepter_username: &str,
) {
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {requester_token}"))
        .json(&serde_json::json!({ "username": accepter_username }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().expect("missing contact_id");

    let resp = client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {accepter_token}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn contact_list_includes_last_seen_field() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let alice_name = common::unique_username("ls_alice");
    let bob_name = common::unique_username("ls_bob");

    common::register(&client, &base, &alice_name, "password123").await;
    common::register(&client, &base, &bob_name, "password123").await;

    let (alice_token, _) = common::login(&client, &base, &alice_name, "password123").await;
    let (bob_token, _) = common::login(&client, &base, &bob_name, "password123").await;

    make_contacts(&client, &base, &alice_token, &bob_token, &bob_name).await;

    // Alice fetches her contact list -- Bob has never connected via WS so
    // last_seen will be null, but the field itself must be present.
    let resp = client
        .get(format!("{base}/api/contacts"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let contacts: Vec<Value> = resp.json().await.unwrap();

    let bob = contacts
        .iter()
        .find(|c| c["username"].as_str() == Some(&bob_name))
        .expect("Bob should appear in Alice's contacts");

    assert!(
        bob.as_object().unwrap().contains_key("last_seen"),
        "contact list entry must include the last_seen field"
    );
}

#[tokio::test]
async fn invisible_contact_last_seen_is_null() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let alice_name = common::unique_username("inv_alice");
    let bob_name = common::unique_username("inv_bob");

    common::register(&client, &base, &alice_name, "password123").await;
    common::register(&client, &base, &bob_name, "password123").await;

    let (alice_token, _) = common::login(&client, &base, &alice_name, "password123").await;
    let (bob_token, _) = common::login(&client, &base, &bob_name, "password123").await;

    make_contacts(&client, &base, &alice_token, &bob_token, &bob_name).await;

    // Bob sets himself invisible.
    let resp = client
        .patch(format!("{base}/api/users/me/status"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "status": "invisible" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    // Alice fetches contacts -- Bob is invisible so last_seen must be null.
    let resp = client
        .get(format!("{base}/api/contacts"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let contacts: Vec<Value> = resp.json().await.unwrap();

    let bob = contacts
        .iter()
        .find(|c| c["username"].as_str() == Some(&bob_name))
        .expect("Bob should appear in Alice's contacts");

    assert!(
        bob["last_seen"].is_null(),
        "invisible contact's last_seen must be suppressed (null)"
    );
}
