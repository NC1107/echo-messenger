//! Prometheus text-format metrics endpoint (`GET /api/metrics`, #1179).
//!
//! ## Auth
//!
//! Gated by `METRICS_TOKEN` env var (read once at server startup into
//! [`AppState::metrics_token`]).  The scraper sends:
//! ```text
//! Authorization: Bearer <METRICS_TOKEN>
//! ```
//! If `METRICS_TOKEN` was **unset** at startup the handler returns `503
//! Service Unavailable` with body `metrics disabled`.  A set-but-wrong token
//! returns `401 Unauthorized`.  This keeps the route safe by default — an
//! operator must explicitly configure the token before scraping works.
//!
//! ## Exposed metrics
//!
//! | Metric | Type | Description |
//! |--------|------|-------------|
//! | `echo_ws_connections` | gauge | Active WebSocket connections (all users/devices) |
//! | `echo_messages_per_second` | gauge | WS relay rate, trailing-60s window |
//! | `echo_failed_logins_total` | counter | Failed login attempts since process start |
//! | `echo_voice_tokens_issued_total` | counter | LiveKit tokens issued since process start |

use std::sync::Arc;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;

use crate::routes::AppState;

const METRICS_DISABLED_BODY: &str = "metrics disabled";
const PROM_CONTENT_TYPE: &str = "text/plain; version=0.0.4; charset=utf-8";

/// Handler for `GET /api/metrics`.
///
/// Returns Prometheus text-format exposition (#1179).
pub async fn get_metrics(
    headers: HeaderMap,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    // Check whether the feature is enabled before looking at the token so the
    // 503 path leaks no information about what a valid token might be.
    let Some(ref expected_token) = state.metrics_token else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            [(axum::http::header::CONTENT_TYPE, "text/plain")],
            METRICS_DISABLED_BODY.to_string(),
        );
    };

    // Constant-time comparison is not strictly necessary here because the
    // token is a secret the operator chose (not a cryptographic nonce), and
    // Prometheus scrapers always send the same static value.  We use a simple
    // `!=` check for clarity; a timing side-channel on this path is not a
    // realistic threat model.
    let provided = extract_bearer_token(&headers).unwrap_or_default();
    if provided != expected_token.as_str() {
        return (
            StatusCode::UNAUTHORIZED,
            [(axum::http::header::CONTENT_TYPE, "text/plain")],
            "unauthorized".to_string(),
        );
    }

    let body = build_prom_output(&state);
    (
        StatusCode::OK,
        [(axum::http::header::CONTENT_TYPE, PROM_CONTENT_TYPE)],
        body,
    )
}

/// Extract the bare token from `Authorization: Bearer <token>`, or `None`.
fn extract_bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
}

/// Render all metrics in the Prometheus text exposition format (v0.0.4).
fn build_prom_output(state: &AppState) -> String {
    let ws_connections = state.hub.connection_count();
    let msg_per_second = state.message_rate.per_second();
    let failed_logins = state.failed_logins.get();
    let voice_tokens = state.voice_tokens_issued.get();

    format!(
        "# HELP echo_ws_connections Active WebSocket connections across all users and devices\n\
         # TYPE echo_ws_connections gauge\n\
         echo_ws_connections {ws_connections}\n\
         # HELP echo_messages_per_second WS message relay rate over the trailing 60-second window\n\
         # TYPE echo_messages_per_second gauge\n\
         echo_messages_per_second {msg_per_second:.6}\n\
         # HELP echo_failed_logins_total Failed login attempts since process start\n\
         # TYPE echo_failed_logins_total counter\n\
         echo_failed_logins_total {failed_logins}\n\
         # HELP echo_voice_tokens_issued_total LiveKit voice tokens issued since process start\n\
         # TYPE echo_voice_tokens_issued_total counter\n\
         echo_voice_tokens_issued_total {voice_tokens}\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_bearer_token_parses_correctly() {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            "Bearer my-secret-token".parse().unwrap(),
        );
        assert_eq!(extract_bearer_token(&headers), Some("my-secret-token"));
    }

    #[test]
    fn extract_bearer_token_returns_none_on_missing_header() {
        let headers = HeaderMap::new();
        assert_eq!(extract_bearer_token(&headers), None);
    }

    #[test]
    fn extract_bearer_token_returns_none_on_non_bearer_scheme() {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            "Basic dXNlcjpwYXNz".parse().unwrap(),
        );
        assert_eq!(extract_bearer_token(&headers), None);
    }
}
