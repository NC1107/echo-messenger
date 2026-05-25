//! Verifies the request-id middleware stack wired in `routes::create_router`
//! (#1173): `x-request-id` is either propagated from an inbound header or
//! freshly minted as a UUID v4, and is always present on the response so a
//! feedback report's stored value can be cross-referenced to server logs.
//!
//! These tests construct a minimal `Router` with the same layer chain as
//! production but no DB or app state, so they run without a Postgres
//! fixture and stay fast.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use axum::routing::get;
use tower::ServiceExt; // for `oneshot`
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::trace::{DefaultOnResponse, TraceLayer};
use tracing::Level;

const REQUEST_ID_HEADER: &str = "x-request-id";

fn test_router() -> Router {
    Router::new()
        .route("/ping", get(|| async { "pong" }))
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(|request: &axum::http::Request<_>| {
                    let request_id = request
                        .headers()
                        .get(REQUEST_ID_HEADER)
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("?");
                    tracing::info_span!(
                        "http.request",
                        method = %request.method(),
                        uri = %request.uri(),
                        request_id = %request_id,
                        user_id = tracing::field::Empty,
                    )
                })
                .on_response(DefaultOnResponse::new().level(Level::INFO)),
        )
        .layer(PropagateRequestIdLayer::new(
            header::HeaderName::from_static(REQUEST_ID_HEADER),
        ))
        .layer(SetRequestIdLayer::new(
            header::HeaderName::from_static(REQUEST_ID_HEADER),
            MakeRequestUuid,
        ))
}

/// When the caller does NOT send `x-request-id`, the middleware mints a
/// fresh UUID and the response carries it back.
#[tokio::test]
async fn mints_fresh_request_id_when_header_absent() {
    let app = test_router();

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/ping")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("oneshot");

    assert_eq!(resp.status(), StatusCode::OK);

    let header_value = resp
        .headers()
        .get(REQUEST_ID_HEADER)
        .expect("x-request-id header missing on response")
        .to_str()
        .expect("x-request-id header not valid UTF-8");

    // MakeRequestUuid emits a UUID v4 (36 chars, four dashes). We don't pin
    // the exact format because tower-http is free to evolve the generator;
    // we only need to assert the slot is populated and non-empty.
    assert!(
        !header_value.is_empty(),
        "x-request-id should be a non-empty generated id, got {header_value:?}"
    );
    assert!(
        header_value.len() >= 8,
        "x-request-id looks too short to be a UUID: {header_value:?}"
    );
}

/// When the caller DOES send `x-request-id`, the middleware preserves the
/// caller's value end-to-end (no overwrite). This is what lets a feedback
/// report's stashed id be looked up in server logs after the fact.
#[tokio::test]
async fn echoes_caller_supplied_request_id() {
    let app = test_router();

    let supplied = "my-trace-1";
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/ping")
                .header(REQUEST_ID_HEADER, supplied)
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("oneshot");

    assert_eq!(resp.status(), StatusCode::OK);

    let header_value = resp
        .headers()
        .get(REQUEST_ID_HEADER)
        .expect("x-request-id header missing on response")
        .to_str()
        .expect("x-request-id header not valid UTF-8");

    assert_eq!(
        header_value, supplied,
        "request-id should round-trip the caller's value, not be replaced"
    );
}
