//! JWT token creation and validation, plus refresh token utilities.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation, decode, encode};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::error::AppError;

#[derive(Debug, Serialize, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub exp: usize,
    pub iat: usize,
    pub iss: String,
    pub aud: String,
}

/// Create a short-lived access token (15 minutes).
pub fn create_token(user_id: Uuid, secret: &str) -> Result<String, AppError> {
    let now = chrono::Utc::now();
    let exp = now
        .checked_add_signed(chrono::Duration::minutes(15))
        .expect("valid timestamp")
        .timestamp() as usize;

    let claims = Claims {
        sub: user_id.to_string(),
        exp,
        iat: now.timestamp() as usize,
        iss: "echo-messenger".to_string(),
        aud: "echo-app".to_string(),
    };

    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;

    Ok(token)
}

#[allow(dead_code)] // Used by AuthUser middleware extractor
pub fn validate_token(token: &str, secret: &str) -> Result<Claims, AppError> {
    let mut validation = Validation::default();
    validation.set_issuer(&["echo-messenger"]);
    validation.set_audience(&["echo-app"]);

    let token_data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )?;

    Ok(token_data.claims)
}

/// Generate a cryptographically random 64-byte refresh token, returned as base64url.
pub fn create_refresh_token() -> String {
    let bytes = rand::random::<[u8; 64]>();
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Hash a refresh token with SHA-256, returning hex-encoded digest.
pub fn hash_refresh_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    let result = hasher.finalize();
    // Manual hex encoding to avoid adding the `hex` crate
    result.iter().fold(String::new(), |mut acc, byte| {
        use std::fmt::Write;
        let _ = write!(acc, "{byte:02x}");
        acc
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_SECRET: &str = "test-jwt-secret-for-unit-tests";

    #[test]
    fn test_create_and_validate_token() {
        let user_id = Uuid::new_v4();
        let token = create_token(user_id, TEST_SECRET).unwrap();
        let claims = validate_token(&token, TEST_SECRET).unwrap();
        assert_eq!(claims.sub, user_id.to_string());
    }

    #[test]
    fn test_wrong_secret_fails() {
        let user_id = Uuid::new_v4();
        let token = create_token(user_id, "secret_a").unwrap();
        let result = validate_token(&token, "secret_b");
        assert!(result.is_err());
    }

    #[test]
    fn test_token_contains_correct_claims() {
        let user_id = Uuid::new_v4();
        let token = create_token(user_id, TEST_SECRET).unwrap();
        let claims = validate_token(&token, TEST_SECRET).unwrap();
        assert_eq!(claims.sub, user_id.to_string());
        // Expiry should be roughly 15 minutes from now
        let now = chrono::Utc::now().timestamp() as usize;
        assert!(claims.exp > now);
        assert!(claims.exp <= now + 15 * 60 + 5); // within 15m + small margin
    }

    #[test]
    fn test_create_refresh_token_is_unique() {
        let t1 = create_refresh_token();
        let t2 = create_refresh_token();
        assert_ne!(t1, t2);
        // 64 bytes base64url-encoded is 86 characters
        assert!(t1.len() >= 80);
    }

    #[test]
    fn test_hash_refresh_token_deterministic() {
        let token = "some-test-token";
        let h1 = hash_refresh_token(token);
        let h2 = hash_refresh_token(token);
        assert_eq!(h1, h2);
    }

    #[test]
    fn test_hash_refresh_token_different_inputs() {
        let h1 = hash_refresh_token("token_a");
        let h2 = hash_refresh_token("token_b");
        assert_ne!(h1, h2);
    }
}
