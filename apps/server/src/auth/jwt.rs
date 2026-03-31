//! JWT token creation and validation.

use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::AppError;

#[derive(Debug, Serialize, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub exp: usize,
}

pub fn create_token(user_id: Uuid, secret: &str) -> Result<String, AppError> {
    let exp = chrono::Utc::now()
        .checked_add_signed(chrono::Duration::days(7))
        .expect("valid timestamp")
        .timestamp() as usize;

    let claims = Claims {
        sub: user_id.to_string(),
        exp,
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
    let token_data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::default(),
    )?;

    Ok(token_data.claims)
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
        // Expiry should be roughly 7 days from now
        let now = chrono::Utc::now().timestamp() as usize;
        assert!(claims.exp > now);
        assert!(claims.exp <= now + 7 * 24 * 3600 + 5); // within 7d + small margin
    }
}
