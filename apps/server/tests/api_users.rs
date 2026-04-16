//! Integration tests for user profile, privacy settings, password change,
//! user search, and account deletion endpoints.

mod common;

use reqwest::Client;
use serde_json::Value;

/// Helper: register a user, log in, return (token, user_id).
async fn setup_user(client: &Client, base: &str, prefix: &str) -> (String, String) {
    let username = common::unique_username(prefix);
    common::register(client, base, &username, "password123").await;
    common::login(client, base, &username, "password123").await
}

// ---------------------------------------------------------------------------
// Profile: GET /api/users/:id/profile
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_own_profile_returns_200() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, user_id) = setup_user(&client, &base, "profget").await;

    let resp = client
        .get(format!("{base}/api/users/{user_id}/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["user_id"].as_str(), Some(user_id.as_str()));
}

#[tokio::test]
async fn get_unknown_profile_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "profunk").await;

    let fake_id = uuid::Uuid::new_v4();
    let resp = client
        .get(format!("{base}/api/users/{fake_id}/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// Profile: PATCH /api/users/me/profile
// ---------------------------------------------------------------------------

#[tokio::test]
async fn update_profile_display_name() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, user_id) = setup_user(&client, &base, "profupd").await;

    let resp = client
        .patch(format!("{base}/api/users/me/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "display_name": "Alice Smith" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["display_name"], "Alice Smith");
    assert_eq!(body["user_id"].as_str(), Some(user_id.as_str()));
}

#[tokio::test]
async fn update_profile_bio_and_status() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "profbio").await;

    let resp = client
        .patch(format!("{base}/api/users/me/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "bio": "I write tests for fun",
            "status_message": "Always caffeinated"
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["bio"], "I write tests for fun");
    assert_eq!(body["status_message"], "Always caffeinated");
}

#[tokio::test]
async fn update_profile_display_name_too_long_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "proflong").await;

    let too_long = "x".repeat(51);
    let resp = client
        .patch(format!("{base}/api/users/me/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "display_name": too_long }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
    let body: Value = resp.json().await.unwrap();
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("Display name")
    );
}

#[tokio::test]
async fn update_profile_invalid_email_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "profemail").await;

    let resp = client
        .patch(format!("{base}/api/users/me/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "email": "not-an-email" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn update_profile_valid_email_succeeds() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "profvalidmail").await;

    let resp = client
        .patch(format!("{base}/api/users/me/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "email": "user@example.com" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn update_profile_invalid_phone_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "profphone").await;

    let resp = client
        .patch(format!("{base}/api/users/me/profile"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "phone": "call me maybe!" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn update_profile_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .patch(format!("{base}/api/users/me/profile"))
        .json(&serde_json::json!({ "display_name": "Ghost" }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Privacy: GET and PATCH /api/users/me/privacy
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_privacy_returns_defaults() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "privget").await;

    let resp = client
        .get(format!("{base}/api/users/me/privacy"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    // Fields must be present
    assert!(body["read_receipts_enabled"].is_boolean());
    assert!(body["email_visible"].is_boolean());
    assert!(body["searchable"].is_boolean());
}

#[tokio::test]
async fn update_privacy_read_receipts() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "privupd").await;

    let resp = client
        .patch(format!("{base}/api/users/me/privacy"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "read_receipts_enabled": false }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["read_receipts_enabled"], false);
}

#[tokio::test]
async fn update_privacy_searchable_false() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "privsearch").await;

    let resp = client
        .patch(format!("{base}/api/users/me/privacy"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "searchable": false }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["searchable"], false);
}

// ---------------------------------------------------------------------------
// Password change: PATCH /api/users/me/password
// ---------------------------------------------------------------------------

#[tokio::test]
async fn change_password_succeeds_with_correct_current() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "pwchange").await;

    let resp = client
        .patch(format!("{base}/api/users/me/password"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "current_password": "password123",
            "new_password": "newpassword456"
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "password_changed");
}

#[tokio::test]
async fn change_password_wrong_current_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "pwwrong").await;

    let resp = client
        .patch(format!("{base}/api/users/me/password"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "current_password": "WRONG_PASSWORD",
            "new_password": "newpassword456"
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn change_password_too_short_returns_400() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "pwshort").await;

    let resp = client
        .patch(format!("{base}/api/users/me/password"))
        .header("Authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "current_password": "password123",
            "new_password": "short"
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 400);
}

// ---------------------------------------------------------------------------
// User search: GET /api/users/search?q=<query>
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_users_returns_results() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let searcher_name = common::unique_username("searcher");
    let target_name = format!("findme_{}", &uuid::Uuid::new_v4().simple().to_string()[..4]);

    common::register(&client, &base, &searcher_name, "password123").await;
    common::register(&client, &base, &target_name, "password123").await;
    let (token, _) = common::login(&client, &base, &searcher_name, "password123").await;

    let resp = client
        .get(format!("{base}/api/users/search?q=findme"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let users = body["users"].as_array().unwrap();
    assert!(
        users
            .iter()
            .any(|u| u["username"].as_str() == Some(&target_name)),
        "target user should appear in search results"
    );
}

#[tokio::test]
async fn search_users_empty_query_returns_empty() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "searchempty").await;

    let resp = client
        .get(format!("{base}/api/users/search?q="))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let users = body["users"].as_array().unwrap();
    assert!(users.is_empty(), "empty query should return no users");
}

#[tokio::test]
async fn search_users_short_query_returns_empty() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "searchshort").await;

    // Single-character queries are rejected (< 2 chars)
    let resp = client
        .get(format!("{base}/api/users/search?q=a"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let users = body["users"].as_array().unwrap();
    assert!(users.is_empty());
}

#[tokio::test]
async fn search_users_does_not_return_self() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let unique_prefix = format!(
        "selfqry_{}",
        &uuid::Uuid::new_v4().simple().to_string()[..4]
    );
    let username = common::unique_username(&unique_prefix);

    common::register(&client, &base, &username, "password123").await;
    let (token, user_id) = common::login(&client, &base, &username, "password123").await;

    let resp = client
        .get(format!("{base}/api/users/search?q={unique_prefix}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let users = body["users"].as_array().unwrap();
    assert!(
        !users
            .iter()
            .any(|u| u["user_id"].as_str() == Some(&user_id)),
        "search should not return the calling user"
    );
}

// ---------------------------------------------------------------------------
// Username invite resolution: GET /api/users/resolve/:username
// ---------------------------------------------------------------------------

#[tokio::test]
async fn resolve_username_invite_returns_contact_relationship() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (alice_token, _alice_id, _alice_name) =
        common::register_and_login(&client, &base, "resdm_a").await;
    let (bob_token, _bob_id, bob_name) =
        common::register_and_login(&client, &base, "resdm_b").await;

    // Alice -> Bob request
    let resp = client
        .post(format!("{base}/api/contacts/request"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .json(&serde_json::json!({ "username": bob_name }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 201);
    let body: Value = resp.json().await.unwrap();
    let contact_id = body["contact_id"].as_str().unwrap().to_string();

    // Bob accepts
    let resp = client
        .post(format!("{base}/api/contacts/accept"))
        .header("Authorization", format!("Bearer {bob_token}"))
        .json(&serde_json::json!({ "contact_id": contact_id }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    let resp = client
        .get(format!("{base}/api/users/resolve/{bob_name}"))
        .header("Authorization", format!("Bearer {alice_token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["username"].as_str(), Some(bob_name.as_str()));
    assert_eq!(body["relationship"].as_str(), Some("contact"));
}

#[tokio::test]
async fn resolve_username_invite_not_found_returns_404() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "resnf").await;

    let resp = client
        .get(format!("{base}/api/users/resolve/does_not_exist_999"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn resolve_username_invite_is_case_insensitive() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (token, _) = setup_user(&client, &base, "rescase").await;
    let target_name = format!(
        "CaseUser{}",
        &uuid::Uuid::new_v4().simple().to_string()[..6]
    );
    common::register(&client, &base, &target_name, "password123").await;
    let lower = target_name.to_lowercase();

    let resp = client
        .get(format!("{base}/api/users/resolve/{lower}"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["username"].as_str(), Some(target_name.as_str()));
}

#[tokio::test]
async fn resolve_username_invite_respects_searchable_privacy_for_strangers() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let (viewer_token, _) = setup_user(&client, &base, "respriv_viewer").await;
    let (target_token, _target_id, target_name) =
        common::register_and_login(&client, &base, "respriv_target").await;

    let resp = client
        .patch(format!("{base}/api/users/me/privacy"))
        .header("Authorization", format!("Bearer {target_token}"))
        .json(&serde_json::json!({ "searchable": false }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);

    let resp = client
        .get(format!("{base}/api/users/resolve/{target_name}"))
        .header("Authorization", format!("Bearer {viewer_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

// ---------------------------------------------------------------------------
// Account deletion: DELETE /api/users/me
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_account_returns_204() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "delacc").await;

    let resp = client
        .delete(format!("{base}/api/users/me"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 204);
}

#[tokio::test]
async fn deleted_user_cannot_login() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("delacc2");
    common::register(&client, &base, &username, "password123").await;
    let (token, _) = common::login(&client, &base, &username, "password123").await;

    // Delete the account
    client
        .delete(format!("{base}/api/users/me"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    // Trying to log in again should fail
    let resp = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({
            "username": username,
            "password": "password123"
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn delete_account_requires_auth() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .delete(format!("{base}/api/users/me"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 401);
}

// ---------------------------------------------------------------------------
// Online users: GET /api/users/online
// ---------------------------------------------------------------------------

#[tokio::test]
async fn online_users_returns_empty_when_no_contacts_online() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let (token, _) = setup_user(&client, &base, "online").await;

    let resp = client
        .get(format!("{base}/api/users/online"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: Value = resp.json().await.unwrap();
    let online = body["online_user_ids"].as_array().unwrap();
    // New user has no contacts connected, so should be empty
    assert!(online.is_empty());
}
