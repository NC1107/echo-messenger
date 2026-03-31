//! Authentication middleware for protected routes.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use std::sync::Arc;
use uuid::Uuid;

use crate::error::AppError;
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

        Ok(AuthUser { user_id })
    }
}
