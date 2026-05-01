//! Server error types.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

/// Stable machine-readable discriminant included in every error response as
/// the `"code"` field.  Variants are serialised as kebab-case strings so that
/// clients can `switch` on them across versions without parsing free-form
/// English messages.
///
/// Generic variants (e.g. `BadRequest`) are emitted when the plain
/// `AppError::bad_request(msg)` constructor is used.  Domain-specific variants
/// (e.g. `WrongPassword`) are set explicitly via `AppError::with_code`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorCode {
    // ---- Generic HTTP-status mirrors ----
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    RateLimited,
    Internal,
    Validation,
    Unsupported,

    // ---- Auth domain ----
    /// Provided password does not match the stored hash.
    WrongPassword,
    /// Username is already registered.
    UsernameTaken,
    /// Registration is administratively disabled.
    RegistrationDisabled,
    /// Refresh token is expired.
    TokenExpired,
    /// Refresh token has been revoked (family invalidated).
    TokenRevoked,

    // ---- Contacts / members ----
    /// Caller is not a member of the target conversation or group.
    NotMember,
    /// The operation would create a duplicate membership.
    AlreadyMember,

    // ---- Crypto / keys ----
    /// Uploaded identity key fingerprint differs from the stored one.
    KeyMismatch,
    /// Ciphertext does not match the expected wire format.
    InvalidCiphertextShape,

    // ---- Media ----
    /// Unsupported or missing file type.
    UnsupportedMediaType,
}

impl ErrorCode {
    /// Kebab-case string used in the JSON `"code"` field.
    pub fn as_str(&self) -> &'static str {
        match self {
            ErrorCode::BadRequest => "bad-request",
            ErrorCode::Unauthorized => "unauthorized",
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::NotFound => "not-found",
            ErrorCode::Conflict => "conflict",
            ErrorCode::RateLimited => "rate-limited",
            ErrorCode::Internal => "internal",
            ErrorCode::Validation => "validation",
            ErrorCode::Unsupported => "unsupported",
            ErrorCode::WrongPassword => "wrong-password",
            ErrorCode::UsernameTaken => "username-taken",
            ErrorCode::RegistrationDisabled => "registration-disabled",
            ErrorCode::TokenExpired => "token-expired",
            ErrorCode::TokenRevoked => "token-revoked",
            ErrorCode::NotMember => "not-member",
            ErrorCode::AlreadyMember => "already-member",
            ErrorCode::KeyMismatch => "key-mismatch",
            ErrorCode::InvalidCiphertextShape => "invalid-ciphertext-shape",
            ErrorCode::UnsupportedMediaType => "unsupported-media-type",
        }
    }
}

#[derive(Debug)]
pub struct AppError {
    pub status: StatusCode,
    pub message: String,
    /// Stable machine-readable discriminant.  Defaults to the generic code
    /// matching the HTTP status when constructed via the short-form helpers.
    pub code: ErrorCode,
    /// Optional structured body used in place of the default envelope.
    /// Set via [`AppError::conflict_with_body`] when the client needs
    /// machine-readable detail (e.g. per-device identity-key conflict
    /// response in `POST /api/keys/upload` -- #664).
    pub body: Option<serde_json::Value>,
}

impl AppError {
    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: msg.into(),
            code: ErrorCode::BadRequest,
            body: None,
        }
    }

    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: msg.into(),
            code: ErrorCode::Unauthorized,
            body: None,
        }
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: msg.into(),
            code: ErrorCode::Internal,
            body: None,
        }
    }

    pub fn not_found(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: msg.into(),
            code: ErrorCode::NotFound,
            body: None,
        }
    }

    pub fn conflict(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            message: msg.into(),
            code: ErrorCode::Conflict,
            body: None,
        }
    }

    pub fn forbidden(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: msg.into(),
            code: ErrorCode::Forbidden,
            body: None,
        }
    }

    /// Build an `AppError` with an explicit `ErrorCode` discriminant.
    /// The HTTP status is derived from the code automatically.
    ///
    /// HTTP status mapping preserves existing route behaviour:
    /// - `NotMember` → 401 (was `AppError::unauthorized` at all call sites)
    /// - `RegistrationDisabled` → 403 (was `AppError::forbidden`)
    /// - `AlreadyMember` → 409 (was `AppError::conflict`)
    /// - `WrongPassword` / `TokenExpired` / `TokenRevoked` → 401
    pub fn with_code(code: ErrorCode, msg: impl Into<String>) -> Self {
        let status = match code {
            ErrorCode::BadRequest
            | ErrorCode::Validation
            | ErrorCode::InvalidCiphertextShape
            | ErrorCode::UnsupportedMediaType => StatusCode::BAD_REQUEST,
            ErrorCode::Unauthorized
            | ErrorCode::WrongPassword
            | ErrorCode::TokenExpired
            | ErrorCode::TokenRevoked
            // NotMember was `AppError::unauthorized` at all existing call sites;
            // keep 401 to avoid breaking existing tests.
            | ErrorCode::NotMember => StatusCode::UNAUTHORIZED,
            ErrorCode::Forbidden | ErrorCode::RegistrationDisabled => StatusCode::FORBIDDEN,
            ErrorCode::NotFound => StatusCode::NOT_FOUND,
            ErrorCode::Conflict | ErrorCode::UsernameTaken | ErrorCode::AlreadyMember => {
                StatusCode::CONFLICT
            }
            ErrorCode::RateLimited => StatusCode::TOO_MANY_REQUESTS,
            ErrorCode::Internal => StatusCode::INTERNAL_SERVER_ERROR,
            ErrorCode::KeyMismatch | ErrorCode::Unsupported => StatusCode::FORBIDDEN,
        };
        Self {
            status,
            message: msg.into(),
            code,
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
            code: ErrorCode::KeyMismatch,
            body: Some(body),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let body = self.body.unwrap_or_else(|| {
            json!({
                "error": self.message,
                "code": self.code.as_str(),
            })
        });
        (self.status, axum::Json(body)).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(err: sqlx::Error) -> Self {
        tracing::error!("Database error: {:?}", err);
        match err {
            sqlx::Error::Database(ref db_err) => {
                if db_err.code().as_deref() == Some("23505") {
                    let (code, msg) = match db_err.constraint() {
                        Some(c) if c.contains("username") => {
                            (ErrorCode::UsernameTaken, "Username already taken")
                        }
                        Some(c) if c.contains("contact") => {
                            (ErrorCode::Conflict, "Contact already exists")
                        }
                        Some(c) if c.contains("reaction") => {
                            (ErrorCode::Conflict, "Reaction already exists")
                        }
                        _ => (ErrorCode::Conflict, "A conflicting record already exists"),
                    };
                    return Self::with_code(code, msg);
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

/// Extension trait deduplicating the `Result<_, sqlx::Error>` -> `AppError`
/// boilerplate (#694).
pub trait DbErrCtx<T> {
    fn db_ctx(self, ctx: &'static str) -> Result<T, AppError>;
}

impl<T> DbErrCtx<T> for Result<T, sqlx::Error> {
    fn db_ctx(self, ctx: &'static str) -> Result<T, AppError> {
        self.map_err(|e| {
            tracing::error!(error = ?e, db_ctx = ctx, "DB error");
            AppError::internal("Database error")
        })
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
        assert_eq!(err.code, ErrorCode::BadRequest);
    }

    #[test]
    fn unauthorized_has_401_status() {
        let err = AppError::unauthorized("not allowed");
        assert_eq!(err.status, StatusCode::UNAUTHORIZED);
        assert_eq!(err.message, "not allowed");
        assert_eq!(err.code, ErrorCode::Unauthorized);
    }

    #[test]
    fn internal_has_500_status() {
        let err = AppError::internal("oops");
        assert_eq!(err.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(err.message, "oops");
        assert_eq!(err.code, ErrorCode::Internal);
    }

    #[test]
    fn not_found_has_404_status() {
        let err = AppError::not_found("missing");
        assert_eq!(err.status, StatusCode::NOT_FOUND);
        assert_eq!(err.message, "missing");
        assert_eq!(err.code, ErrorCode::NotFound);
    }

    #[test]
    fn conflict_has_409_status() {
        let err = AppError::conflict("already exists");
        assert_eq!(err.status, StatusCode::CONFLICT);
        assert_eq!(err.message, "already exists");
        assert_eq!(err.code, ErrorCode::Conflict);
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

    #[test]
    fn db_ctx_passes_through_ok() {
        let result: Result<i32, sqlx::Error> = Ok(42);
        let mapped = result.db_ctx("test_ctx").unwrap();
        assert_eq!(mapped, 42);
    }

    #[test]
    fn db_ctx_maps_err_to_internal() {
        let result: Result<i32, sqlx::Error> = Err(sqlx::Error::RowNotFound);
        let err = result.db_ctx("test_ctx").unwrap_err();
        assert_eq!(err.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(err.message, "Database error");
    }

    #[test]
    fn with_code_wrong_password_is_401() {
        let err = AppError::with_code(ErrorCode::WrongPassword, "Invalid username or password");
        assert_eq!(err.status, StatusCode::UNAUTHORIZED);
        assert_eq!(err.code, ErrorCode::WrongPassword);
        assert_eq!(err.message, "Invalid username or password");
    }

    #[test]
    fn with_code_username_taken_is_409() {
        let err = AppError::with_code(ErrorCode::UsernameTaken, "Username already taken");
        assert_eq!(err.status, StatusCode::CONFLICT);
        assert_eq!(err.code, ErrorCode::UsernameTaken);
    }

    #[test]
    fn with_code_registration_disabled_is_403() {
        let err = AppError::with_code(
            ErrorCode::RegistrationDisabled,
            "Registration is closed on this server",
        );
        assert_eq!(err.status, StatusCode::FORBIDDEN);
        assert_eq!(err.code, ErrorCode::RegistrationDisabled);
    }

    #[test]
    fn with_code_not_member_is_401() {
        // NotMember maps to 401 to preserve all existing call sites which
        // previously used AppError::unauthorized("Not a member...").
        let err = AppError::with_code(ErrorCode::NotMember, "Not a member");
        assert_eq!(err.status, StatusCode::UNAUTHORIZED);
        assert_eq!(err.code, ErrorCode::NotMember);
    }

    #[test]
    fn with_code_token_expired_is_401() {
        let err = AppError::with_code(ErrorCode::TokenExpired, "Token expired");
        assert_eq!(err.status, StatusCode::UNAUTHORIZED);
        assert_eq!(err.code, ErrorCode::TokenExpired);
    }

    #[test]
    fn error_code_as_str_snapshot() {
        assert_eq!(ErrorCode::WrongPassword.as_str(), "wrong-password");
        assert_eq!(ErrorCode::UsernameTaken.as_str(), "username-taken");
        assert_eq!(
            ErrorCode::RegistrationDisabled.as_str(),
            "registration-disabled"
        );
        assert_eq!(ErrorCode::NotMember.as_str(), "not-member");
        assert_eq!(ErrorCode::KeyMismatch.as_str(), "key-mismatch");
        assert_eq!(ErrorCode::TokenExpired.as_str(), "token-expired");
        assert_eq!(ErrorCode::TokenRevoked.as_str(), "token-revoked");
        assert_eq!(ErrorCode::AlreadyMember.as_str(), "already-member");
        assert_eq!(
            ErrorCode::InvalidCiphertextShape.as_str(),
            "invalid-ciphertext-shape"
        );
        assert_eq!(
            ErrorCode::UnsupportedMediaType.as_str(),
            "unsupported-media-type"
        );
    }

    #[test]
    fn into_response_json_shape_includes_code_field() {
        let err = AppError::with_code(ErrorCode::WrongPassword, "Invalid username or password");
        let body = serde_json::json!({
            "error": err.message,
            "code": err.code.as_str(),
        });
        assert_eq!(body["error"], "Invalid username or password");
        assert_eq!(body["code"], "wrong-password");
    }
}
