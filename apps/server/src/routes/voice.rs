//! LiveKit voice/video token generation.

use axum::Json;
use axum::extract::State;
use chrono::Utc;
use jsonwebtoken::{EncodingKey, Header, encode};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::middleware::AuthUser;
use crate::error::AppError;
use crate::routes::AppState;

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub room: String,
    pub identity: String,
}

#[derive(Debug, Serialize)]
pub struct TokenResponse {
    pub token: String,
}

/// LiveKit video grant claims.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct VideoGrant {
    room: String,
    room_join: bool,
    can_publish: bool,
    can_subscribe: bool,
}

/// Full LiveKit JWT claims.
#[derive(Debug, Serialize)]
struct LiveKitClaims {
    iss: String,
    sub: String,
    iat: i64,
    exp: i64,
    video: VideoGrant,
}

/// Generate a LiveKit access token for voice/video channels.
///
/// POST /api/voice/token
/// Requires authentication. The caller's identity is verified against their
/// auth token to prevent impersonation.
pub async fn generate_token(
    auth: AuthUser,
    _state: State<Arc<AppState>>,
    Json(body): Json<TokenRequest>,
) -> Result<Json<TokenResponse>, AppError> {
    // Verify the requested identity matches the authenticated user
    if body.identity != auth.user_id.to_string() {
        return Err(AppError::bad_request(
            "Identity must match authenticated user",
        ));
    }

    if body.room.is_empty() {
        return Err(AppError::bad_request("Room name is required"));
    }

    let api_key = std::env::var("LIVEKIT_API_KEY")
        .map_err(|_| AppError::internal("LiveKit is not configured"))?;
    let api_secret = std::env::var("LIVEKIT_API_SECRET")
        .map_err(|_| AppError::internal("LiveKit is not configured"))?;

    let now = Utc::now().timestamp();
    let claims = LiveKitClaims {
        iss: api_key,
        sub: body.identity,
        iat: now,
        exp: now + 3600, // 1 hour
        video: VideoGrant {
            room: body.room,
            room_join: true,
            can_publish: true,
            can_subscribe: true,
        },
    };

    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(api_secret.as_bytes()),
    )
    .map_err(|e| {
        tracing::error!("Failed to encode LiveKit token: {:?}", e);
        AppError::internal("Failed to generate voice token")
    })?;

    Ok(Json(TokenResponse { token }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_livekit_claims_serialization() {
        let claims = LiveKitClaims {
            iss: "test-key".into(),
            sub: "user-123".into(),
            iat: 1000,
            exp: 4600,
            video: VideoGrant {
                room: "room:channel".into(),
                room_join: true,
                can_publish: true,
                can_subscribe: true,
            },
        };

        let json = serde_json::to_value(&claims).unwrap();
        assert_eq!(json["iss"], "test-key");
        assert_eq!(json["sub"], "user-123");
        assert_eq!(json["video"]["room"], "room:channel");
        assert_eq!(json["video"]["roomJoin"], true);
        assert_eq!(json["video"]["canPublish"], true);
        assert_eq!(json["video"]["canSubscribe"], true);
    }
}
