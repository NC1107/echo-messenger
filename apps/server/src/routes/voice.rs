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

/// Lifetime of a minted LiveKit access token, in seconds.
///
/// Deliberately short (5 minutes). The token grants room-join + publish, and
/// the server has no LiveKit management client wired (see `evict_from_voice`
/// below), so a participant who is kicked or banned from the conversation can
/// keep an *already-minted* token until it expires. A short window caps that
/// window of access at 5 minutes instead of an hour (VL-14 / VL-24). The
/// LiveKit client SDK refreshes the grant transparently before expiry for
/// participants who are still members, so legitimate long calls are unaffected.
const TOKEN_TTL_SECS: i64 = 5 * 60;

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub identity: Option<String>,
    /// Alternative field name used by some mobile clients.
    pub channel_id: Option<String>,
    /// Conversation context -- the room name is derived from this so the
    /// LiveKit grant cannot be steered to a conversation the caller is not
    /// a member of.
    pub conversation_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct TokenResponse {
    pub token: String,
    /// LiveKit signaling URL the client should connect to.  Returned only
    /// when `LIVEKIT_URL` is configured on the server, so ops can point the
    /// client at a managed LiveKit (e.g. `wss://*.livekit.cloud`) or a
    /// non-default subdomain without a client release (#721).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

/// LiveKit video grant claims.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct VideoGrant {
    room: String,
    room_join: bool,
    can_publish: bool,
    can_subscribe: bool,
    /// Required so `LocalParticipant.setName(username)` can update the
    /// display name on the SFU. Without this the client's metadata update
    /// fails with NOT_ALLOWED, which then closes the signal channel and
    /// makes every subsequent operation (setMicrophoneEnabled, publish)
    /// fail — surfacing as an "iOS crash on voice lounge join" report.
    can_update_own_metadata: bool,
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
    // Username doubles as the LiveKit display name; avoids a setName race.
    let user = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .db_ctx("looking up user for voice token")?
        .ok_or_else(|| AppError::not_found("User not found"))?;

    let username = user.username;

    // Identity collision fix: when the client doesn't supply an explicit
    // identity we append a per-issuance nonce so successive join attempts
    // present as distinct participants to the LiveKit SFU. Without this,
    // a rejoin within the SFU's ~15-second participant-idle window collides
    // with the previous (still-tracked) participant of the same identity
    // and publish requests time out (LiveKit `TimeoutException` after 10s
    // on `setMicrophoneEnabled`). The display name is set separately via
    // `setName(username)` on the client, so the nonce never reaches the UI.
    //
    // Identity max length on LiveKit is 64; an 8-char nonce keeps the
    // composite well under that even with a 30-char max username.
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let nonce = &nonce[..8];
    let default_identity = format!("{username}#{nonce}");
    let identity = body.identity.unwrap_or(default_identity);

    // Identity must be the username, the nonced default, or the user_id —
    // prevents impersonation while permitting the new `username#nonce` form.
    let is_valid_identity = identity == username
        || identity == auth.user_id.to_string()
        || identity
            .strip_prefix(&format!("{username}#"))
            .is_some_and(|tail| tail.len() == 8 && tail.chars().all(|c| c.is_ascii_hexdigit()));
    if !is_valid_identity {
        return Err(AppError::bad_request(
            "Identity must match authenticated user",
        ));
    }

    // SECURITY: room name derives from the SAME conversation the membership
    // check runs against; the old `body.room` allowed cross-room escalation.
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
        exp: now + TOKEN_TTL_SECS,
        video: VideoGrant {
            room,
            room_join: true,
            can_publish: true,
            can_subscribe: true,
            can_update_own_metadata: true,
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

    // Optional override; client falls back to `wss://livekit.<server-host>`.
    let url = std::env::var("LIVEKIT_URL")
        .ok()
        .filter(|u| !u.trim().is_empty());

    state.voice_tokens_issued.inc();
    Ok(Json(TokenResponse { token, url }))
}

/// Forcibly disconnect a participant from the LiveKit SFU (VL-24).
///
/// DEFERRED — needs a LiveKit RoomService management client that is not yet
/// wired into this server. Today the server only *mints* tokens (raw
/// `jsonwebtoken` JWTs); it never calls back into LiveKit, so there is no way
/// to actively evict a participant who is already connected to the SFU. The
/// short [`TOKEN_TTL_SECS`] window is the mitigation in the meantime: a kicked
/// user keeps SFU access for at most that window because their next token
/// refresh fails the membership check in [`generate_token`].
///
/// To complete this:
///   1. Add the `livekit-api` crate (`RoomServiceClient`) to
///      `apps/server/Cargo.toml`.
///   2. Construct the client from `LIVEKIT_URL` + `LIVEKIT_API_KEY` +
///      `LIVEKIT_API_SECRET` (already read here) and stash it on `AppState`.
///   3. Call `room_service.remove_participant(room, identity)` for every active
///      `voice_sessions` row of the removed user. Because the LiveKit identity
///      is `username#nonce` (not stable), the caller must look up the live
///      participant identities from the SFU (`list_participants`) and match by
///      the `username#` prefix, since the server does not persist the nonce.
///
/// Integration point: call this from
/// `routes::groups::members::after_member_loss` (and `lifecycle::leave_group`),
/// right after [`db::channels::leave_all_user_voice_sessions`] clears the
/// server-side presence rows.
#[allow(dead_code)]
async fn evict_from_voice_deferred() {
    // Intentionally unimplemented — see doc comment above.
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
    fn token_ttl_is_short_window() {
        // VL-14 / VL-24: a kicked user's already-minted token must self-expire
        // quickly. Guard against an accidental regression back to the 1h grant.
        // Kept <= 10 min so a removed member loses SFU access promptly.
        assert_eq!(TOKEN_TTL_SECS, 300, "token TTL should be 5 minutes");
    }

    #[test]
    fn minted_token_carries_short_expiry() {
        // Mirror the mint path and verify the encoded JWT's exp/iat span equals
        // the configured TTL (so a decoded token expires within the window).
        let now = Utc::now().timestamp();
        let claims = LiveKitClaims {
            iss: "test-key".into(),
            sub: "user#abcdef12".into(),
            iat: now,
            exp: now + TOKEN_TTL_SECS,
            video: VideoGrant {
                room: "00000000-0000-0000-0000-000000000000".into(),
                room_join: true,
                can_publish: true,
                can_subscribe: true,
                can_update_own_metadata: true,
            },
        };
        let secret = "test-secret";
        let token = encode(
            &Header::default(),
            &claims,
            &EncodingKey::from_secret(secret.as_bytes()),
        )
        .unwrap();

        let mut validation = jsonwebtoken::Validation::default();
        validation.validate_exp = false;
        let decoded = jsonwebtoken::decode::<serde_json::Value>(
            &token,
            &jsonwebtoken::DecodingKey::from_secret(secret.as_bytes()),
            &validation,
        )
        .unwrap();
        let exp = decoded.claims["exp"].as_i64().unwrap();
        let iat = decoded.claims["iat"].as_i64().unwrap();
        assert_eq!(exp - iat, TOKEN_TTL_SECS);
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
                can_update_own_metadata: true,
            },
        };

        let json = serde_json::to_value(&claims).unwrap();
        assert_eq!(json["iss"], "test-key");
        assert_eq!(json["sub"], "user-123");
        assert_eq!(json["video"]["room"], "room:channel");
        assert_eq!(json["video"]["roomJoin"], true);
        assert_eq!(json["video"]["canPublish"], true);
        assert_eq!(json["video"]["canUpdateOwnMetadata"], true);
        assert_eq!(json["video"]["canSubscribe"], true);
    }

    #[test]
    fn token_response_omits_url_when_none() {
        let resp = TokenResponse {
            token: "jwt".into(),
            url: None,
        };
        let json = serde_json::to_value(&resp).unwrap();
        assert_eq!(json["token"], "jwt");
        assert!(json.get("url").is_none(), "url must be omitted when None");
    }

    #[test]
    fn token_response_includes_url_when_set() {
        let resp = TokenResponse {
            token: "jwt".into(),
            url: Some("wss://livekit.example.com".into()),
        };
        let json = serde_json::to_value(&resp).unwrap();
        assert_eq!(json["url"], "wss://livekit.example.com");
    }
}
