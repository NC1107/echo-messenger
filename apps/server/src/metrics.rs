//! Lightweight in-memory counters that back the operator dashboard
//! (`/api/admin/stats/realtime`, #681).
//!
//! ## Privacy invariant
//!
//! These counters carry **no** per-user, per-conversation, or
//! per-message-content identification.  The only thing we track is "a
//! relay happened, now."  That keeps the metrics surface compatible with
//! the design-doc invariant in `docs/group-e2e-design/` (no content,
//! no decrypted previews, aggregated counts only).
//!
//! ## Hot-path contract
//!
//! [`MessageRateCounter::record`] runs inside the WS message relay path
//! and must not introduce contention.  The implementation is a single
//! relaxed `AtomicU64` fetch-add plus a `Mutex<VecDeque<...>>` lock that
//! is taken only when the seconds bucket rolls over (~once per second
//! across the whole server, not per message).  Under steady load the
//! mutex is effectively cold; the atomic increment is the only thing the
//! hot path touches.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Monotonically-increasing counter for a single event type (e.g. failed logins,
/// voice-token issuances). Increment with [`SimpleCounter::inc`]; read the
/// running total with [`SimpleCounter::get`].
///
/// Backed by a single relaxed `AtomicU64` — no allocation, no lock, safe to
/// call on hot paths.
#[derive(Debug, Default)]
pub struct SimpleCounter(AtomicU64);

impl SimpleCounter {
    pub const fn new() -> Self {
        Self(AtomicU64::new(0))
    }

    /// Increment by one.
    #[inline]
    pub fn inc(&self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }

    /// Read the current value.
    #[inline]
    pub fn get(&self) -> u64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// Sliding window length for [`MessageRateCounter::per_second`].
/// Sixty seconds matches the dashboard's "messages per second" tile —
/// long enough to smooth quiet periods, short enough that an operator
/// notices a flood within ~a minute.
const WINDOW: Duration = Duration::from_secs(60);

/// Records each successful WS message relay and reports a sliding-window
/// per-second rate.
#[derive(Debug)]
pub struct MessageRateCounter {
    /// Counter for the bucket currently being filled.  Read+reset under
    /// the mutex once per second (or when the caller asks for a snapshot),
    /// so the relay path only does a relaxed fetch-add.
    current_bucket: AtomicU64,
    /// `(bucket_start, count)` for each completed second still inside the
    /// 60-second window.  Locked only when buckets roll over — every
    /// ~1 s on a hot server, never on a quiet one.
    history: Mutex<RateHistory>,
}

#[derive(Debug)]
struct RateHistory {
    /// `Instant` at which the current bucket started.
    current_started: Instant,
    /// Completed buckets, oldest first.  Capacity is bounded by `WINDOW`
    /// in seconds, so this never grows beyond ~60 entries.
    buckets: std::collections::VecDeque<(Instant, u64)>,
}

impl Default for MessageRateCounter {
    fn default() -> Self {
        Self::new()
    }
}

impl MessageRateCounter {
    pub fn new() -> Self {
        Self {
            current_bucket: AtomicU64::new(0),
            history: Mutex::new(RateHistory {
                current_started: Instant::now(),
                buckets: std::collections::VecDeque::with_capacity(64),
            }),
        }
    }

    /// Mark one successful relay. Hot path — must stay lock-free in the
    /// common case (no bucket roll).
    #[inline]
    pub fn record(&self) {
        self.current_bucket.fetch_add(1, Ordering::Relaxed);
    }

    /// Per-second rate over the trailing [`WINDOW`].  Computes by
    /// rolling stale buckets out of the window, snapshotting the current
    /// bucket, and dividing the sum by the window length.
    pub fn per_second(&self) -> f64 {
        let now = Instant::now();
        let mut history = self.history.lock().expect("metrics mutex poisoned");

        // swap-to-zero so back-to-back per_second calls can't double-count.
        if now.duration_since(history.current_started) >= Duration::from_secs(1) {
            let count = self.current_bucket.swap(0, Ordering::Relaxed);
            let started = history.current_started;
            history.buckets.push_back((started, count));
            history.current_started = now;
        }

        // Drop buckets older than the window.
        let cutoff = now - WINDOW;
        while let Some((started, _)) = history.buckets.front() {
            if *started + Duration::from_secs(1) < cutoff {
                history.buckets.pop_front();
            } else {
                break;
            }
        }

        let historical: u64 = history.buckets.iter().map(|(_, n)| *n).sum();
        let in_progress = self.current_bucket.load(Ordering::Relaxed);
        let total = historical + in_progress;
        let seconds = WINDOW.as_secs_f64();
        total as f64 / seconds
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newly_constructed_counter_is_zero() {
        let c = MessageRateCounter::new();
        assert!(c.per_second().abs() < f64::EPSILON);
    }

    #[test]
    fn records_contribute_to_rate() {
        let c = MessageRateCounter::new();
        for _ in 0..120 {
            c.record();
        }
        // 120 events in <1s → contribute to the 60s window → 2.0 per second.
        let rate = c.per_second();
        assert!((rate - 2.0).abs() < 0.001, "expected 2.0 msg/s, got {rate}");
    }
}
