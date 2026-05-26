//! Per-user "min iat" token-invalidation map (CR-4).
//!
//! Closes the gap where a revoked device's 15-minute access token continued
//! to authorize every REST call until the JWT expired. The JWT validator
//! only checks `iss`/`aud`/`exp`; it has no knowledge of device revocation.
//!
//! Strategy: whenever a user revokes a device, changes their password, or
//! does anything that should invalidate outstanding access tokens, we bump
//! `min_iat` for that user to `now()`. The `AuthUser` extractor rejects any
//! JWT whose `iat` is older than `min_iat`.
//!
//! In-memory only by design: the worst-case after a server restart is that
//! tokens issued before the restart remain valid until their 15-minute TTL —
//! the same window we accept today. Persistent state would require a
//! migration and an extra DB round-trip per request; the trade-off favours
//! the simpler in-memory map.
//!
//! Concurrency: `DashMap` is lock-free for the read-heavy path (one read per
//! authenticated request). Writes happen only on revocation events, which
//! are several orders of magnitude rarer.

use dashmap::DashMap;
use std::sync::Arc;
use uuid::Uuid;

#[derive(Clone, Default)]
pub struct TokenInvalidator {
    /// user_id → unix-seconds floor. JWTs with `iat < floor` are rejected.
    min_iat: Arc<DashMap<Uuid, i64>>,
}

impl TokenInvalidator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the floor `iat` (unix seconds) below which tokens for
    /// `user_id` are rejected, or `None` if no invalidation has been
    /// recorded for this user.
    pub fn min_iat(&self, user_id: Uuid) -> Option<i64> {
        self.min_iat.get(&user_id).map(|v| *v)
    }

    /// Mark every access token currently outstanding for `user_id` as
    /// invalid. Idempotent; bumps the floor to `now` only if `now` is
    /// strictly greater than the existing floor (so a clock skew can't
    /// roll it backward).
    pub fn invalidate(&self, user_id: Uuid) {
        let now = chrono::Utc::now().timestamp();
        self.min_iat
            .entry(user_id)
            .and_modify(|prev| {
                if now > *prev {
                    *prev = now;
                }
            })
            .or_insert(now);
    }

    /// `true` iff the supplied JWT `iat` (unix seconds) is still valid for
    /// `user_id`. Returns `true` when no invalidation is recorded for this
    /// user (the common case).
    pub fn is_token_valid(&self, user_id: Uuid, iat: i64) -> bool {
        match self.min_iat(user_id) {
            Some(floor) => iat >= floor,
            None => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_user_is_valid() {
        let inv = TokenInvalidator::new();
        assert!(inv.is_token_valid(Uuid::new_v4(), 0));
    }

    #[test]
    fn invalidate_rejects_older_iat() {
        let inv = TokenInvalidator::new();
        let user = Uuid::new_v4();
        let before = chrono::Utc::now().timestamp() - 10;
        inv.invalidate(user);
        assert!(!inv.is_token_valid(user, before));
    }

    #[test]
    fn invalidate_keeps_newer_iat_valid() {
        let inv = TokenInvalidator::new();
        let user = Uuid::new_v4();
        inv.invalidate(user);
        let after = chrono::Utc::now().timestamp() + 60;
        assert!(inv.is_token_valid(user, after));
    }

    #[test]
    fn invalidate_does_not_roll_floor_backward() {
        let inv = TokenInvalidator::new();
        let user = Uuid::new_v4();
        inv.invalidate(user);
        let first = inv.min_iat(user).unwrap();
        // Second invalidation cannot lower the floor.
        inv.invalidate(user);
        let second = inv.min_iat(user).unwrap();
        assert!(second >= first);
    }
}
