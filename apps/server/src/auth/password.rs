//! Argon2id password hashing.

use argon2::password_hash::SaltString;
use argon2::password_hash::rand_core::OsRng;
use argon2::{Algorithm, Argon2, Params, PasswordHash, PasswordHasher, PasswordVerifier, Version};

use crate::error::AppError;

/// TD-49: pin Argon2id parameters explicitly instead of relying on the
/// crate's `default()`.
///
/// `Argon2::default()` is currently `m=19_456 KiB, t=2, p=1` (OWASP minimum)
/// but the upstream defaults change between crate releases. Pinning here
/// guarantees that:
///
/// 1. A future `argon2` dep bump can't silently soften our parameters.
/// 2. The `DUMMY_HASH` constant baked into `routes/auth.rs` (used for
///    constant-time username-enumeration defence on login) stays bit-for-bit
///    consistent with what we mint, so the timing-equalisation pass
///    actually equalises.
///
/// Output length is left at the Params default (32 bytes) which matches the
/// length encoded in DUMMY_HASH.
fn argon2() -> Argon2<'static> {
    // OWASP Argon2id recommended minimum (2023): m=19 MiB, t=2, p=1.
    let params = Params::new(19_456, 2, 1, None).expect("Argon2 params are statically valid");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

pub fn hash_password(password: &str) -> Result<String, AppError> {
    let salt = SaltString::generate(&mut OsRng);
    let hash = argon2().hash_password(password.as_bytes(), &salt)?;
    Ok(hash.to_string())
}

pub fn verify_password(password: &str, hash: &str) -> Result<bool, AppError> {
    let parsed_hash =
        PasswordHash::new(hash).map_err(|e| AppError::internal(format!("Invalid hash: {e}")))?;
    match argon2().verify_password(password.as_bytes(), &parsed_hash) {
        Ok(()) => Ok(true),
        Err(argon2::password_hash::Error::Password) => Ok(false),
        Err(e) => Err(AppError::from(e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash_and_verify() {
        let password = "super_secret_password";
        let hash = hash_password(password).unwrap();
        assert!(verify_password(password, &hash).unwrap());
    }

    #[test]
    fn test_wrong_password_fails() {
        let hash = hash_password("correct_password").unwrap();
        let result = verify_password("wrong_password", &hash).unwrap();
        assert!(!result);
    }

    #[test]
    fn test_different_passwords_different_hashes() {
        let password = "same_password";
        let hash1 = hash_password(password).unwrap();
        let hash2 = hash_password(password).unwrap();
        // Salted hashing produces different outputs each time
        assert_ne!(hash1, hash2);
    }
}
