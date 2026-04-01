//! Authentication endpoints: register, login.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::{jwt, password};
use crate::db;
use crate::error::AppError;

use super::AppState;

#[derive(Debug, Deserialize)]
pub struct AuthRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub user_id: String,
    pub access_token: String,
    pub avatar_url: Option<String>,
}

fn validate_username(username: &str) -> Result<(), AppError> {
    if username.len() < 3 || username.len() > 32 {
        return Err(AppError::bad_request(
            "Username must be between 3 and 32 characters",
        ));
    }
    if !username
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return Err(AppError::bad_request(
            "Username must contain only alphanumeric characters and underscores",
        ));
    }
    Ok(())
}

fn validate_password(password: &str) -> Result<(), AppError> {
    if password.len() < 8 {
        return Err(AppError::bad_request(
            "Password must be at least 8 characters",
        ));
    }
    Ok(())
}

pub async fn register(
    State(state): State<Arc<AppState>>,
    Json(body): Json<AuthRequest>,
) -> Result<impl IntoResponse, AppError> {
    validate_username(&body.username)?;
    validate_password(&body.password)?;

    let password_hash = password::hash_password(&body.password)?;
    let user_id = db::users::create_user(&state.pool, &body.username, &password_hash).await?;
    let access_token = jwt::create_token(user_id, &state.jwt_secret)?;

    let response = AuthResponse {
        user_id: user_id.to_string(),
        access_token,
        avatar_url: None,
    };

    Ok((StatusCode::CREATED, Json(response)))
}

pub async fn login(
    State(state): State<Arc<AppState>>,
    Json(body): Json<AuthRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = db::users::find_by_username(&state.pool, &body.username)
        .await?
        .ok_or_else(|| AppError::unauthorized("Invalid username or password"))?;

    let valid = password::verify_password(&body.password, &user.password_hash)?;
    if !valid {
        return Err(AppError::unauthorized("Invalid username or password"));
    }

    let access_token = jwt::create_token(user.id, &state.jwt_secret)?;

    let response = AuthResponse {
        user_id: user.id.to_string(),
        access_token,
        avatar_url: user.avatar_url,
    };

    Ok(Json(response))
}
