//! Integration tests for authentication endpoints.

mod common;

use reqwest::Client;

#[tokio::test]
async fn register_returns_201() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("reg201");

    let resp = common::register_raw(&client, &base, &username, "password123").await;
    assert_eq!(resp.status().as_u16(), 201);
}

#[tokio::test]
async fn register_duplicate_returns_409() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("regdup");

    let first = common::register_raw(&client, &base, &username, "password123").await;
    assert_eq!(first.status().as_u16(), 201);

    let second = common::register_raw(&client, &base, &username, "password123").await;
    assert_eq!(second.status().as_u16(), 409);
}

#[tokio::test]
async fn login_returns_tokens() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("logintok");

    common::register(&client, &base, &username, "password123").await;

    let resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(resp.status().as_u16(), 200);

    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());
    assert!(body["user_id"].as_str().is_some());
}

#[tokio::test]
async fn login_wrong_password_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("loginbad");

    common::register(&client, &base, &username, "password123").await;

    let resp = common::login_raw(&client, &base, &username, "wrong_password").await;
    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn protected_route_without_token_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .get(format!("{base}/api/contacts"))
        .send()
        .await
        .expect("request failed");

    assert_eq!(resp.status().as_u16(), 401);
}

#[tokio::test]
async fn refresh_token_returns_new_tokens() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("refresh");

    common::register(&client, &base, &username, "password123").await;
    let login_body: serde_json::Value = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({ "username": username, "password": "password123" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let refresh_token = login_body["refresh_token"].as_str().unwrap();

    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());
}

#[tokio::test]
async fn refresh_token_revoked_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("revoked");

    common::register(&client, &base, &username, "password123").await;
    let login_body: serde_json::Value = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({ "username": username, "password": "password123" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let refresh_token = login_body["refresh_token"].as_str().unwrap();

    // First refresh — consumes (revokes) the original token
    let resp1 = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp1.status().as_u16(), 200);

    // Replay the SAME old token — should fail (theft detection)
    let resp2 = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await
        .unwrap();
    assert_eq!(
        resp2.status().as_u16(),
        401,
        "replaying a revoked refresh token should return 401"
    );
}

// ---------------------------------------------------------------------------
// HttpOnly refresh-token cookie (#342)
// ---------------------------------------------------------------------------

/// Find the first `Set-Cookie` header whose value starts with `name=`.
fn find_set_cookie<'a>(resp: &'a reqwest::Response, name: &str) -> Option<&'a str> {
    let prefix = format!("{name}=");
    resp.headers()
        .get_all(reqwest::header::SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|s| s.starts_with(&prefix))
}

/// Assert a Set-Cookie header has the expected security attributes.
fn assert_refresh_cookie_attrs(set_cookie: &str, expect_max_age: &str) {
    let lower = set_cookie.to_ascii_lowercase();
    assert!(lower.contains("httponly"), "missing HttpOnly: {set_cookie}");
    assert!(lower.contains("secure"), "missing Secure: {set_cookie}");
    assert!(
        lower.contains("samesite=strict"),
        "missing SameSite=Strict: {set_cookie}"
    );
    assert!(
        lower.contains("path=/api/auth"),
        "missing Path=/api/auth: {set_cookie}"
    );
    assert!(
        lower.contains(&format!("max-age={expect_max_age}")),
        "expected Max-Age={expect_max_age}: {set_cookie}"
    );
}

#[tokio::test]
async fn login_sets_refresh_cookie() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("cookielogin");

    common::register(&client, &base, &username, "password123").await;
    let resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(resp.status().as_u16(), 200);

    let set_cookie =
        find_set_cookie(&resp, "echo_refresh").expect("login should set echo_refresh cookie");
    assert_refresh_cookie_attrs(set_cookie, "604800");
}

/// Regression guard for the three security flags the issue specifically tracks.
/// Each attribute is asserted independently so a single missing flag fails the
/// test immediately with an actionable message, rather than being masked by
/// other assertions in the shared helper.
///
/// - `HttpOnly` — JavaScript cannot read the cookie, preventing token theft
///   via XSS.
/// - `Secure` — the cookie is transmitted over HTTPS only, preventing
///   interception on plain-HTTP connections.
/// - `SameSite=Strict` — the cookie is not sent on cross-site requests,
///   mitigating CSRF attacks against the `/api/auth/refresh` endpoint.
#[tokio::test]
async fn login_refresh_cookie_has_httponly_secure_samesite_strict() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("websecflags");

    common::register(&client, &base, &username, "password123").await;
    let resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(resp.status().as_u16(), 200);

    let set_cookie = find_set_cookie(&resp, "echo_refresh")
        .expect("Set-Cookie: echo_refresh must be present on login");
    let lower = set_cookie.to_ascii_lowercase();

    assert!(
        lower.contains("httponly"),
        "echo_refresh cookie is missing HttpOnly -- JS can read the token: {set_cookie}"
    );
    assert!(
        lower.contains("secure"),
        "echo_refresh cookie is missing Secure -- token transmitted over plain HTTP: {set_cookie}"
    );
    assert!(
        lower.contains("samesite=strict"),
        "echo_refresh cookie is missing SameSite=Strict -- CSRF risk on /refresh: {set_cookie}"
    );
}

#[tokio::test]
async fn register_sets_refresh_cookie() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("cookiereg");

    let resp = common::register_raw(&client, &base, &username, "password123").await;
    assert_eq!(resp.status().as_u16(), 201);

    let set_cookie =
        find_set_cookie(&resp, "echo_refresh").expect("register should set echo_refresh cookie");
    assert_refresh_cookie_attrs(set_cookie, "604800");
}

#[tokio::test]
async fn logout_clears_refresh_cookie() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("cookielogout");

    common::register(&client, &base, &username, "password123").await;
    let (token, _user_id) = common::login(&client, &base, &username, "password123").await;

    let resp = client
        .post(format!("{base}/api/auth/logout"))
        .header("Authorization", format!("Bearer {token}"))
        .send()
        .await
        .expect("logout request failed");
    assert_eq!(resp.status().as_u16(), 204);

    let set_cookie =
        find_set_cookie(&resp, "echo_refresh").expect("logout should clear echo_refresh cookie");
    assert_refresh_cookie_attrs(set_cookie, "0");
}

#[tokio::test]
async fn refresh_via_cookie_only() {
    let base = common::spawn_server().await;
    // Echo's refresh cookie sets `Secure`, which reqwest's cookie_store would
    // drop over plaintext HTTP. The test server is plain HTTP, so we attach
    // the cookie header manually below instead of relying on the jar.
    let client = Client::new();

    let username = common::unique_username("refcookie");
    common::register(&client, &base, &username, "password123").await;
    let login_resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(login_resp.status().as_u16(), 200);

    let raw_cookie = find_set_cookie(&login_resp, "echo_refresh")
        .expect("login Set-Cookie")
        .to_string();
    let cookie_value = raw_cookie
        .split(';')
        .next()
        .expect("cookie name=value")
        .trim()
        .to_string();

    // Send /refresh with empty body and the cookie attached manually.
    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .header(reqwest::header::COOKIE, &cookie_value)
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("refresh request failed");

    assert_eq!(resp.status().as_u16(), 200);
    let new_set_cookie =
        find_set_cookie(&resp, "echo_refresh").expect("refresh should rotate cookie");
    assert_refresh_cookie_attrs(new_set_cookie, "604800");

    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());
}

#[tokio::test]
async fn refresh_via_body_still_works() {
    // Backward-compatibility check: mobile/desktop clients have no cookie jar.
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("refbody");

    common::register(&client, &base, &username, "password123").await;
    let login_body: serde_json::Value = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({ "username": username, "password": "password123" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let refresh_token = login_body["refresh_token"].as_str().unwrap();

    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status().as_u16(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());
}

#[tokio::test]
async fn refresh_cookie_takes_precedence() {
    // When both a valid cookie and a stale/invalid body token are present,
    // the cookie wins -- the body cannot override the HttpOnly cookie.
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("refprec");

    common::register(&client, &base, &username, "password123").await;
    let login_resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(login_resp.status().as_u16(), 200);

    let raw_cookie = find_set_cookie(&login_resp, "echo_refresh")
        .expect("login Set-Cookie")
        .to_string();
    let cookie_value = raw_cookie
        .split(';')
        .next()
        .expect("cookie name=value")
        .trim()
        .to_string();

    // Body carries a junk token. Cookie carries the real one. Cookie wins.
    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .header(reqwest::header::COOKIE, &cookie_value)
        .json(&serde_json::json!({ "refresh_token": "deadbeef-not-a-real-token" }))
        .send()
        .await
        .expect("refresh request failed");

    assert_eq!(
        resp.status().as_u16(),
        200,
        "cookie should take precedence over body"
    );
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["access_token"].as_str().is_some());
    assert!(body["refresh_token"].as_str().is_some());
}

/// /refresh with NEITHER a cookie NOR a body token must 401 -- the only
/// new error branch introduced by the cookie path (#342).
#[tokio::test]
async fn refresh_with_no_token_anywhere_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();

    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("refresh request failed");

    assert_eq!(
        resp.status().as_u16(),
        401,
        "no cookie + no body must be unauthorized"
    );
}

/// After /logout the server-side refresh token is revoked.  Replaying the
/// previously-set cookie value against /refresh must therefore 401 even
/// though the cookie attributes themselves still parse cleanly (#342).
#[tokio::test]
async fn refresh_with_logged_out_cookie_returns_401() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("logoutreplay");

    common::register(&client, &base, &username, "password123").await;
    let login_resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(login_resp.status().as_u16(), 200);

    let raw_cookie = find_set_cookie(&login_resp, "echo_refresh")
        .expect("login Set-Cookie")
        .to_string();
    let cookie_header = raw_cookie
        .split(';')
        .next()
        .expect("cookie name=value")
        .trim()
        .to_string();

    let body: serde_json::Value = login_resp.json().await.unwrap();
    let access_token = body["access_token"].as_str().unwrap().to_string();

    // Log out -- revokes the refresh family server-side and clears the cookie.
    let resp = client
        .post(format!("{base}/api/auth/logout"))
        .header("Authorization", format!("Bearer {access_token}"))
        .send()
        .await
        .expect("logout request failed");
    assert_eq!(resp.status().as_u16(), 204);

    // Replay the captured cookie -- server must reject because the underlying
    // refresh family was revoked.
    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .header(reqwest::header::COOKIE, &cookie_header)
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("refresh request failed");
    assert_eq!(
        resp.status().as_u16(),
        401,
        "revoked cookie must not refresh"
    );
}

/// A cleared cookie (`echo_refresh=`) must NOT short-circuit the body token
/// lookup -- the empty-string filter in the cookie/body resolution chain
/// is what makes mobile/desktop fallback robust when a stale cleared cookie
/// is still attached by the browser (#342).
#[tokio::test]
async fn refresh_empty_cookie_falls_through_to_body() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("emptycookie");

    common::register(&client, &base, &username, "password123").await;
    let login_body: serde_json::Value = client
        .post(format!("{base}/api/auth/login"))
        .json(&serde_json::json!({ "username": username, "password": "password123" }))
        .send()
        .await
        .expect("login failed")
        .json()
        .await
        .unwrap();
    let body_token = login_body["refresh_token"].as_str().unwrap().to_string();

    // Send an empty echo_refresh cookie alongside a valid body token.  The
    // server's `.filter(|s| !s.is_empty())` guard must let the body token win.
    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .header(reqwest::header::COOKIE, "echo_refresh=")
        .json(&serde_json::json!({ "refresh_token": body_token }))
        .send()
        .await
        .expect("refresh request failed");

    assert_eq!(
        resp.status().as_u16(),
        200,
        "empty cookie must fall through to body token, not 401"
    );
}

/// A web client that refreshes via the cookie path must invalidate the body
/// token issued at login as part of the same family rotation.  Without this
/// guarantee, an XSS that captured the body token at login could keep using
/// it after the cookie was rotated -- defeating the point of the cookie
/// (#342).
#[tokio::test]
async fn refresh_cookie_rotation_invalidates_prior_body_token() {
    let base = common::spawn_server().await;
    let client = Client::new();
    let username = common::unique_username("mixedmode");

    common::register(&client, &base, &username, "password123").await;
    let login_resp = common::login_raw(&client, &base, &username, "password123").await;
    assert_eq!(login_resp.status().as_u16(), 200);

    let raw_cookie = find_set_cookie(&login_resp, "echo_refresh")
        .expect("login Set-Cookie")
        .to_string();
    let cookie_header = raw_cookie
        .split(';')
        .next()
        .expect("cookie name=value")
        .trim()
        .to_string();

    let body: serde_json::Value = login_resp.json().await.unwrap();
    let original_body_token = body["refresh_token"].as_str().unwrap().to_string();

    // Rotate via the cookie path.
    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .header(reqwest::header::COOKIE, &cookie_header)
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("cookie refresh failed");
    assert_eq!(
        resp.status().as_u16(),
        200,
        "cookie rotation should succeed"
    );

    // The body token from login is now superseded -- replaying it must 401.
    let resp = client
        .post(format!("{base}/api/auth/refresh"))
        .json(&serde_json::json!({ "refresh_token": original_body_token }))
        .send()
        .await
        .expect("body refresh request failed");
    assert_eq!(
        resp.status().as_u16(),
        401,
        "body token must be invalidated by cookie-path rotation"
    );
}
