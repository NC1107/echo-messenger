//! LiveKit voice/video token generation.

use axum::Json;
use axum::extract::State;
use chrono::Utc;
use jsonwebtoken::{EncodingKey, Header, encode};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx};
use crate::routes::AppState;

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub identity: Option<String>,
    /// Alternative field name used by some mobile clients.
    pub channel_id: Option<String>,
    /// Conversation context -- the room name is derived from this so the
    /// LiveKit grant cannot be steered to a conversation the caller is not
    /// a member of (CRIT-1, audit 2026-04-30).
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
        .db_ctx("looking up user for voice token")?
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

    // Security: derive the LiveKit room name from the conversation the caller
    // claims membership of, then check membership against THAT same value.
    // Earlier code accepted a separate `body.room` that was used as the JWT
    // claim while membership was checked against `conversation_id`, so a
    // member of conv A could request `{room: "<victim>", conversation_id: "<A>"}`
    // and receive a token granting access to the victim's room (CRIT-1).
    let conversation_id_str = body.conversation_id.or(body.channel_id).ok_or_else(|| {
        AppError::bad_request("conversation_id or channel_id is required for voice token")
    })?;

    let conv_uuid = uuid::Uuid::parse_str(&conversation_id_str)
        .map_err(|_| AppError::bad_request("Invalid conversation_id or channel_id"))?;

    let is_member = db::groups::is_member(&state.pool, conv_uuid, auth.user_id)
        .await
        .db_ctx("checking voice token membership")?;
    if !is_member {
        return Err(AppError::bad_request("Not a member of this conversation"));
    }

    // Use the conversation UUID (canonical, hyphenated) as the LiveKit room
    // name -- safe by construction (alphanumeric + hyphens, <= 36 chars).
    let room = conv_uuid.to_string();

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
    fn test_room_name_validation() {
        // Valid names
        for name in ["room-123", "abc_def", "room:channel", "abc123", "A-B_C:D"] {
            assert!(
                name.len() <= 128
                    && name
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ':'),
                "Expected valid: {name}"
            );
        }
        // Invalid names
        for name in [
            "room name",
            "room/../../etc",
            "room\n",
            "<script>",
            "room;DROP",
        ] {
            assert!(
                !name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ':'),
                "Expected invalid: {name}"
            );
        }
    }

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
