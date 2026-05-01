//! Integration test: POST /api/auth/register returns 403 when
//! REGISTRATION_OPEN is set to a falsy value (#685).
//!
//! `registration_open()` reads the env var at call time, so we set it in the
//! process environment before the request and restore it afterward.  Tests
//! are isolated by unique usernames; the env mutation is protected by a
//! tokio::sync::Mutex so parallel async test workers cannot interfere.

mod common;

use reqwest::Client;
use tokio::sync::Mutex;

/// Serialize env mutations so parallel async test workers don't clobber each other.
static ENV_LOCK: Mutex<()> = Mutex::const_new(());

/// Helper: attempt registration and return the HTTP status code.
async fn try_register(base: &str) -> u16 {
    let client = Client::new();
    let username = common::unique_username("reg_disabled");
    client
        .post(format!("{base}/api/auth/register"))
        .json(&serde_json::json!({
            "username": username,
            "password": "password123",
        }))
        .send()
        .await
        .expect("register request failed")
        .status()
        .as_u16()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// When REGISTRATION_OPEN is unset (the default), registration succeeds.
#[tokio::test]
async fn register_succeeds_when_env_unset() {
    let base = common::spawn_server().await;

    let _guard = ENV_LOCK.lock().await;
    // Ensure the var is absent for this test.
    // SAFETY: serialized by ENV_LOCK; no other thread mutates this var concurrently.
    unsafe { std::env::remove_var("REGISTRATION_OPEN") };

    let status = try_register(&base).await;
    assert_eq!(status, 201, "registration should succeed when env is unset");
}

/// When REGISTRATION_OPEN=false, the register endpoint must return 403.
#[tokio::test]
async fn register_blocked_when_registration_closed() {
    let base = common::spawn_server().await;

    let _guard = ENV_LOCK.lock().await;
    // SAFETY: serialized by ENV_LOCK; no other thread mutates this var concurrently.
    unsafe { std::env::set_var("REGISTRATION_OPEN", "false") };

    let status = try_register(&base).await;

    // Restore before releasing the lock.
    unsafe { std::env::remove_var("REGISTRATION_OPEN") };

    assert_eq!(
        status, 403,
        "register must return 403 when REGISTRATION_OPEN=false"
    );
}

/// Falsy aliases (0 / no / off) must also produce 403.
#[tokio::test]
async fn register_blocked_for_all_falsy_aliases() {
    let base = common::spawn_server().await;

    for alias in &["0", "no", "off"] {
        let _guard = ENV_LOCK.lock().await;
        // SAFETY: serialized by ENV_LOCK; no other thread mutates this var concurrently.
        unsafe { std::env::set_var("REGISTRATION_OPEN", alias) };

        let status = try_register(&base).await;
        unsafe { std::env::remove_var("REGISTRATION_OPEN") };

        assert_eq!(
            status, 403,
            "register must return 403 when REGISTRATION_OPEN={alias}"
        );
    }
}
