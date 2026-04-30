//! Server error types.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

#[derive(Debug)]
pub struct AppError {
    pub status: StatusCode,
    pub message: String,
    /// Optional structured body used in place of the default `{"error": ...}`
    /// envelope. Set via [`AppError::conflict_with_body`] when the client needs
    /// machine-readable detail (e.g. the per-device identity-key conflict
    /// response in `POST /api/keys/upload` -- #664).
    pub body: Option<serde_json::Value>,
}

impl AppError {
    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: msg.into(),
            body: None,
        }
    }

    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: msg.into(),
            body: None,
        }
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: msg.into(),
            body: None,
        }
    }

    pub fn not_found(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: msg.into(),
            body: None,
        }
    }

    pub fn conflict(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            message: msg.into(),
            body: None,
        }
    }

    /// 409 Conflict that carries a structured JSON body. Used for the
    /// per-device identity-key conflict so the client can extract `device_id`
    /// + expected/actual fingerprints without parsing English error strings.
    pub fn conflict_with_body(body: serde_json::Value) -> Self {
        let message = body
            .get("code")
            .and_then(|v| v.as_str())
            .unwrap_or("conflict")
            .to_string();
        Self {
            status: StatusCode::CONFLICT,
            message,
            body: Some(body),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let body = self
            .body
            .unwrap_or_else(|| json!({ "error": self.message }));
        (self.status, axum::Json(body)).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(err: sqlx::Error) -> Self {
        tracing::error!("Database error: {:?}", err);
        match err {
            sqlx::Error::Database(ref db_err) => {
                // Unique violation — use constraint name for specific messages
                if db_err.code().as_deref() == Some("23505") {
                    let msg = match db_err.constraint() {
                        Some(c) if c.contains("username") => "Username already taken",
                        Some(c) if c.contains("contact") => "Contact already exists",
                        Some(c) if c.contains("reaction") => "Reaction already exists",
                        _ => "A conflicting record already exists",
                    };
                    return Self::conflict(msg);
                }
                Self::internal("Database error")
            }
            _ => Self::internal("Database error"),
        }
    }
}

impl From<jsonwebtoken::errors::Error> for AppError {
    fn from(err: jsonwebtoken::errors::Error) -> Self {
        tracing::error!("JWT error: {:?}", err);
        Self::unauthorized("Invalid or expired token")
    }
}

impl From<argon2::password_hash::Error> for AppError {
    fn from(err: argon2::password_hash::Error) -> Self {
        tracing::error!("Password hash error: {:?}", err);
        Self::internal("Authentication error")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bad_request_has_400_status() {
        let err = AppError::bad_request("bad input");
        assert_eq!(err.status, StatusCode::BAD_REQUEST);
        assert_eq!(err.message, "bad input");
    }

    #[test]
    fn unauthorized_has_401_status() {
        let err = AppError::unauthorized("not allowed");
        assert_eq!(err.status, StatusCode::UNAUTHORIZED);
        assert_eq!(err.message, "not allowed");
    }

    #[test]
    fn internal_has_500_status() {
        let err = AppError::internal("oops");
        assert_eq!(err.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(err.message, "oops");
    }

    #[test]
    fn not_found_has_404_status() {
        let err = AppError::not_found("missing");
        assert_eq!(err.status, StatusCode::NOT_FOUND);
        assert_eq!(err.message, "missing");
    }

    #[test]
    fn conflict_has_409_status() {
        let err = AppError::conflict("already exists");
        assert_eq!(err.status, StatusCode::CONFLICT);
        assert_eq!(err.message, "already exists");
    }

    #[test]
    fn bad_request_accepts_string_literal() {
        let err = AppError::bad_request("literal");
        assert_eq!(err.message, "literal");
    }

    #[test]
    fn bad_request_accepts_owned_string() {
        let msg = "owned".to_string();
        let err = AppError::bad_request(msg);
        assert_eq!(err.message, "owned");
    }

    #[test]
    fn debug_impl_contains_message() {
        let err = AppError::bad_request("debug me");
        let debug_str = format!("{err:?}");
        assert!(
            debug_str.contains("debug me"),
            "Debug output should contain message"
        );
    }
}
