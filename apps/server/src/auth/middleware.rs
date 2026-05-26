//! Authentication middleware for protected routes.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use std::sync::Arc;
use uuid::Uuid;

use crate::error::{AppError, ErrorCode};
use crate::routes::AppState;

use super::jwt;

#[derive(Debug, Clone)]
pub struct AuthUser {
    pub user_id: Uuid,
}

impl FromRequestParts<Arc<AppState>> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let auth_header = parts
            .headers
            .get("Authorization")
            .and_then(|v| v.to_str().ok())
            .ok_or_else(|| AppError::unauthorized("Missing Authorization header"))?;

        let token = auth_header
            .strip_prefix("Bearer ")
            .ok_or_else(|| AppError::unauthorized("Invalid Authorization header format"))?;

        let claims = jwt::validate_token(token, &state.jwt_secret)?;

        let user_id = Uuid::parse_str(&claims.sub)
            .map_err(|_| AppError::unauthorized("Invalid user ID in token"))?;

        // CR-4: reject tokens whose `iat` predates the user's last
        // revocation event (device revoke, password change, "log out
        // everywhere"). Closes the 15-minute access-token window where a
        // revoked credential continued to authorize every REST call.
        if !state
            .token_invalidator
            .is_token_valid(user_id, claims.iat as i64)
        {
            return Err(AppError::with_code(
                ErrorCode::TokenRevoked,
                "Access token has been revoked",
            ));
        }

        // Light up the `user_id` slot reserved by the per-request tracing
        // span (see `routes::create_router`). The TraceLayer span is opened
        // before handler extractors run, so this is the only point at which
        // we know which user (if any) the request belongs to (#1173).
        tracing::Span::current().record("user_id", tracing::field::display(user_id));

        Ok(AuthUser { user_id })
    }
}
