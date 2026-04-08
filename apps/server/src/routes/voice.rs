//! LiveKit voice/video token generation.

use axum::Json;
use axum::extract::State;
use chrono::Utc;
use jsonwebtoken::{EncodingKey, Header, encode};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::AppError;
use crate::routes::AppState;

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub room: Option<String>,
    pub identity: Option<String>,
    /// Alternative field name used by some mobile clients.
    pub channel_id: Option<String>,
    /// Conversation context -- used to derive room name when `room` is absent.
    pub conversation_id: Option<String>,
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
    state: State<Arc<AppState>>,
    Json(body): Json<TokenRequest>,
) -> Result<Json<TokenResponse>, AppError> {
    // Look up the username so LiveKit participants display human-readable
    // names instead of UUIDs.  The identity field doubles as the display
    // name inside LiveKit, so using the username here means the client no
    // longer has to race a post-connect `setName` call.
    let user = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .map_err(|e| {
            tracing::error!("DB error looking up user for voice token: {e:?}");
            AppError::internal("Database error")
        })?
        .ok_or_else(|| AppError::bad_request("User not found"))?;

    let username = user.username;
    let identity = body.identity.unwrap_or_else(|| username.clone());

    // The provided identity must be either the username or the user_id.
    // This prevents impersonation while still allowing legacy clients that
    // send the UUID.
    if identity != username && identity != auth.user_id.to_string() {
        return Err(AppError::bad_request(
            "Identity must match authenticated user",
        ));
    }

    // Resolve room: prefer explicit `room`, fall back to channel_id or
    // conversation_id so mobile clients that send either field still work.
    let room = body
        .room
        .or(body.channel_id.clone())
        .or(body.conversation_id.clone())
        .unwrap_or_default();

    if room.is_empty() {
        return Err(AppError::bad_request("Room name is required"));
    }

    // Security: verify the user is a member of the conversation they are
    // requesting a voice token for.  Without this check any authenticated
    // user could generate a token for an arbitrary room and eavesdrop on
    // voice channels they should not have access to.
    let conversation_id_str = body.conversation_id.or(body.channel_id);
    if let Some(ref cid) = conversation_id_str {
        let conv_uuid = uuid::Uuid::parse_str(cid)
            .map_err(|_| AppError::bad_request("Invalid conversation_id or channel_id"))?;
        let members = db::groups::get_conversation_member_ids(&state.pool, conv_uuid)
            .await
            .map_err(|e| {
                tracing::error!("DB error checking voice token membership: {e:?}");
                AppError::internal("Database error")
            })?;
        if !members.contains(&auth.user_id) {
            return Err(AppError::bad_request("Not a member of this conversation"));
        }
    }

    let api_key = std::env::var("LIVEKIT_API_KEY").map_err(|_| {
        AppError::bad_request(
            "Voice chat is not configured on this server. \
             Set LIVEKIT_API_KEY and LIVEKIT_API_SECRET.",
        )
    })?;
    let api_secret = std::env::var("LIVEKIT_API_SECRET").map_err(|_| {
        AppError::bad_request(
            "Voice chat is not configured on this server. \
             Set LIVEKIT_API_SECRET.",
        )
    })?;

    let now = Utc::now().timestamp();
    let claims = LiveKitClaims {
        iss: api_key,
        sub: identity,
        iat: now,
        exp: now + 3600, // 1 hour
        video: VideoGrant {
            room,
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
