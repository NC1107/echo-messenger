//! Integration tests for trusted-proxy IP extraction in rate-limit middleware.
//!
//! The test server binds on 127.0.0.1, so every reqwest connection arrives
//! with peer IP 127.0.0.1.  By configuring 127.0.0.1 as a trusted proxy we
//! can verify that X-Real-IP / X-Forwarded-For headers are honoured and that
//! different spoofed client IPs get independent rate-limit buckets.

mod common;

use reqwest::Client;
use std::net::IpAddr;

/// Send a login POST and return the HTTP status code.
async fn try_login(client: &Client, base: &str, header_name: &str, header_value: &str) -> u16 {
    client
        .post(format!("{base}/api/auth/login"))
        .header(header_name, header_value)
        .json(&serde_json::json!({
            "username": "nonexistent_user_proxy_test",
            "password": "wrongpass",
        }))
        .send()
        .await
        .expect("request failed")
        .status()
        .as_u16()
}

// ---------------------------------------------------------------------------
// Without trusted proxy: proxy headers must be ignored
// ---------------------------------------------------------------------------

/// Without a trusted proxy configured, X-Real-IP headers from clients must be
/// ignored.  All requests from 127.0.0.1 share the same rate-limit bucket
/// regardless of what X-Real-IP they send.
#[tokio::test]
async fn rate_limit_ignores_x_real_ip_without_trusted_proxy() {
    let base = common::spawn_server().await; // no trusted proxies
    let client = Client::new();

    // Exhaust the login bucket for 127.0.0.1 (5 attempts).
    for _ in 0..5 {
        let status = try_login(&client, &base, "x-real-ip", "1.2.3.4").await;
        // 401 = wrong credentials (bucket not yet full), anything but 429.
        assert_ne!(
            status, 429,
            "should not be rate-limited before limit is reached"
        );
    }

    // The 6th request must be rejected regardless of what X-Real-IP it sends,
    // because 127.0.0.1 (the peer) is the effective key and its bucket is full.
    let status = try_login(&client, &base, "x-real-ip", "9.9.9.9").await;
    assert_eq!(
        status, 429,
        "6th request from 127.0.0.1 should be rate-limited even with a different X-Real-IP"
    );
}

// ---------------------------------------------------------------------------
// With trusted proxy: X-Real-IP is honoured
// ---------------------------------------------------------------------------

/// When 127.0.0.1 is a trusted proxy, X-Real-IP is used as the rate-limit key.
/// Two different X-Real-IP values must have independent buckets.
#[tokio::test]
async fn rate_limit_honours_x_real_ip_from_trusted_proxy() {
    let loopback: IpAddr = "127.0.0.1".parse().unwrap();
    let base = common::spawn_server_with_trusted_proxies(vec![loopback]).await;
    let client = Client::new();

    // Exhaust the login bucket for X-Real-IP 1.2.3.4 (5 attempts).
    for _ in 0..5 {
        let status = try_login(&client, &base, "x-real-ip", "1.2.3.4").await;
        assert_ne!(
            status, 429,
            "should not be rate-limited before limit is reached"
        );
    }

    // 6th request for 1.2.3.4 must be rate-limited.
    let status = try_login(&client, &base, "x-real-ip", "1.2.3.4").await;
    assert_eq!(
        status, 429,
        "6th request for 1.2.3.4 should be rate-limited"
    );

    // A different X-Real-IP must still be allowed (independent bucket).
    let status = try_login(&client, &base, "x-real-ip", "5.6.7.8").await;
    assert_ne!(
        status, 429,
        "first request for 5.6.7.8 should not be rate-limited"
    );
}

// ---------------------------------------------------------------------------
// With trusted proxy: X-Forwarded-For is honoured as fallback
// ---------------------------------------------------------------------------

/// When 127.0.0.1 is a trusted proxy and no X-Real-IP header is present,
/// X-Forwarded-For (last public IP in the chain) is used as the rate-limit key.
#[tokio::test]
async fn rate_limit_honours_x_forwarded_for_from_trusted_proxy() {
    let loopback: IpAddr = "127.0.0.1".parse().unwrap();
    let base = common::spawn_server_with_trusted_proxies(vec![loopback]).await;
    let client = Client::new();

    // Exhaust the login bucket for XFF IP 203.0.113.10 (5 attempts).
    // Use "spoofed, 203.0.113.10" to verify we use the *last* (proxy-appended) IP.
    for _ in 0..5 {
        let status = try_login(
            &client,
            &base,
            "x-forwarded-for",
            "spoofed_ip, 203.0.113.10",
        )
        .await;
        assert_ne!(
            status, 429,
            "should not be rate-limited before limit is reached"
        );
    }

    // 6th request for 203.0.113.10 must be rate-limited.
    let status = try_login(
        &client,
        &base,
        "x-forwarded-for",
        "spoofed_ip, 203.0.113.10",
    )
    .await;
    assert_eq!(
        status, 429,
        "6th request for 203.0.113.10 should be rate-limited"
    );

    // A different XFF IP must still be allowed.
    let status = try_login(&client, &base, "x-forwarded-for", "203.0.113.99").await;
    assert_ne!(
        status, 429,
        "first request for 203.0.113.99 should not be rate-limited"
    );
}
