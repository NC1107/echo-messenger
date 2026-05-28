//! Per-lounge canvas authority store.
//!
//! Implements the "single avatar slot per user, most-recently-active device is
//! the canvas authority" policy decided in
//! `docs/voice-lounge/03-multi-device.md`.
//!
//! State is in-memory only: a user leaving the lounge clears authority, and
//! the next event from any of their devices implicitly claims it again. There
//! is **no DB persistence** — restart wipes everything, which is fine because
//! the canvas authority is per-live-lounge state, not durable user data.
//!
//! Concurrency: a single `DashMap` keyed by `(user_id, channel_id)` so claims
//! from different users (or the same user in different lounges) never
//! contend.

use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use uuid::Uuid;

/// 1-second grace window after a successful `claim`. Mash-tapping the canvas
/// on two devices within the window can't oscillate authority back and forth.
const CLAIM_GRACE: Duration = Duration::from_millis(1000);

#[derive(Debug, Clone, Copy)]
struct AuthorityEntry {
    device_id: i32,
    claimed_at: Instant,
}

/// In-memory authority store. Cheap to clone (internal `Arc<DashMap>`).
#[derive(Debug, Default, Clone)]
pub struct CanvasAuthority {
    inner: Arc<DashMap<(Uuid, Uuid), AuthorityEntry>>,
}

impl CanvasAuthority {
    pub fn new() -> Self {
        Self::default()
    }

    /// Current authority device for `(user_id, channel_id)`, or `None` when
    /// no device has claimed yet.
    pub fn current(&self, user_id: Uuid, channel_id: Uuid) -> Option<i32> {
        self.inner.get(&(user_id, channel_id)).map(|e| e.device_id)
    }

    /// Implicit claim: a canvas event arrived from `device_id` and no
    /// authority is recorded yet. Returns `true` if this call established
    /// authority (caller may want to broadcast). Returns `false` if some
    /// other device already holds it — the caller should drop the event.
    ///
    /// Unlike `claim`, this never overwrites an existing entry and never
    /// considers the grace window: the first writer wins on cold start.
    pub fn claim_if_absent(&self, user_id: Uuid, channel_id: Uuid, device_id: i32) -> bool {
        use dashmap::mapref::entry::Entry;
        match self.inner.entry((user_id, channel_id)) {
            Entry::Occupied(occupied) => occupied.get().device_id == device_id,
            Entry::Vacant(vacant) => {
                vacant.insert(AuthorityEntry {
                    device_id,
                    claimed_at: Instant::now(),
                });
                true
            }
        }
    }

    /// Explicit claim from `canvas_authority_claim`. Returns `true` when
    /// authority changed (or was set for the first time) so the caller can
    /// broadcast `canvas_authority_changed`. A claim from the device that
    /// already holds authority is a no-op (returns `false`). Claims within
    /// the grace window from a different device are rejected (returns
    /// `false`) to prevent oscillation.
    pub fn claim(&self, user_id: Uuid, channel_id: Uuid, device_id: i32) -> bool {
        use dashmap::mapref::entry::Entry;
        let now = Instant::now();
        match self.inner.entry((user_id, channel_id)) {
            Entry::Vacant(vacant) => {
                vacant.insert(AuthorityEntry {
                    device_id,
                    claimed_at: now,
                });
                true
            }
            Entry::Occupied(mut occupied) => {
                let existing = *occupied.get();
                if existing.device_id == device_id {
                    return false;
                }
                if Self::within_grace(existing.claimed_at, now) {
                    return false;
                }
                occupied.insert(AuthorityEntry {
                    device_id,
                    claimed_at: now,
                });
                true
            }
        }
    }

    /// Drop the authority entry for `(user_id, channel_id)` — call this from
    /// the voice-leave path so the next device to draw reclaims fresh.
    pub fn clear_on_leave(&self, user_id: Uuid, channel_id: Uuid) {
        self.inner.remove(&(user_id, channel_id));
    }

    /// Whether `claimed_at` is still inside the grace window relative to
    /// `now`. Extracted so the `claim` branch logic stays under the
    /// cognitive-complexity budget (≤15).
    fn within_grace(claimed_at: Instant, now: Instant) -> bool {
        now.saturating_duration_since(claimed_at) < CLAIM_GRACE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread::sleep;

    fn ids() -> (Uuid, Uuid) {
        (Uuid::new_v4(), Uuid::new_v4())
    }

    #[test]
    fn current_returns_none_before_any_claim() {
        let store = CanvasAuthority::new();
        let (u, c) = ids();
        assert_eq!(store.current(u, c), None);
    }

    #[test]
    fn first_implicit_claim_wins() {
        let store = CanvasAuthority::new();
        let (u, c) = ids();
        assert!(store.claim_if_absent(u, c, 1));
        assert_eq!(store.current(u, c), Some(1));
        // Second device's implicit attempt is rejected.
        assert!(!store.claim_if_absent(u, c, 2));
        assert_eq!(store.current(u, c), Some(1));
    }

    #[test]
    fn explicit_claim_within_grace_is_rejected() {
        let store = CanvasAuthority::new();
        let (u, c) = ids();
        assert!(store.claim(u, c, 1));
        assert!(!store.claim(u, c, 2), "claim within grace window must fail");
        assert_eq!(store.current(u, c), Some(1));
    }

    #[test]
    fn explicit_claim_after_grace_succeeds() {
        let store = CanvasAuthority::new();
        let (u, c) = ids();
        assert!(store.claim(u, c, 1));
        sleep(CLAIM_GRACE + Duration::from_millis(50));
        assert!(store.claim(u, c, 2), "claim after grace must succeed");
        assert_eq!(store.current(u, c), Some(2));
    }

    #[test]
    fn claim_from_same_device_is_noop() {
        let store = CanvasAuthority::new();
        let (u, c) = ids();
        assert!(store.claim(u, c, 1));
        assert!(!store.claim(u, c, 1), "self-claim returns false");
    }

    #[test]
    fn clear_on_leave_drops_entry() {
        let store = CanvasAuthority::new();
        let (u, c) = ids();
        assert!(store.claim(u, c, 1));
        store.clear_on_leave(u, c);
        assert_eq!(store.current(u, c), None);
        // After clear, a fresh implicit claim from a different device wins.
        assert!(store.claim_if_absent(u, c, 2));
        assert_eq!(store.current(u, c), Some(2));
    }

    #[test]
    fn authority_is_per_lounge() {
        let store = CanvasAuthority::new();
        let u = Uuid::new_v4();
        let lounge_a = Uuid::new_v4();
        let lounge_b = Uuid::new_v4();
        assert!(store.claim(u, lounge_a, 1));
        // Device 2 in a *different* lounge can claim immediately.
        assert!(
            store.claim(u, lounge_b, 2),
            "per-lounge authority must not share grace state"
        );
        assert_eq!(store.current(u, lounge_a), Some(1));
        assert_eq!(store.current(u, lounge_b), Some(2));
    }
}
