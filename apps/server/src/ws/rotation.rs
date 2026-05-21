//! Server-led leader election for group-key rotation.
//!
//! When a member is removed/banned/leaves an encrypted group, the server
//! emits a `group_key_rotation_requested` event so the remaining members
//! can mint a new envelope batch at the bumped key version. Today (pre
//! Phase 3b) every online member races; the database UNIQUE constraint on
//! `(conversation_id, key_version)` ensures one writer wins and the losers
//! get HTTP 409. That is *correct* but noisy: at modest group sizes every
//! rotation produces N-1 wasted POSTs, and the failure modes (every
//! racing client crashes before completing) leave the group wedged with no
//! deterministic recovery owner.
//!
//! Phase 3b — described in
//! [`docs/group-e2e-design/03-recommended-protocol.md`](../../../../../docs/group-e2e-design/03-recommended-protocol.md)
//! — moves the election server-side. The server is the only component
//! that authoritatively sees both the current membership and the live
//! online set (via the WS hub). It picks the lowest-`user_id` online
//! member as `leader`, sorts the remaining online members ascending as
//! `fallback_order`, and ships both to every recipient inside the
//! rotation-requested event. Clients respect the hint: the leader fires
//! immediately, every other client waits `deadline_ms` per fallback slot
//! before attempting. The `(conversation_id, key_version)` UNIQUE
//! constraint remains the safety net for the cases the election misses
//! (split-brain, retried trigger, leader crashes before the upload).
//!
//! This module owns only the *pure* election logic. The handler in
//! `routes/groups/members.rs` is responsible for snapshotting the online
//! set and assembling the event payload around it. Keeping the
//! computation pure makes it cheap to unit-test against synthetic member
//! lists without spinning up the WS hub or a DB pool.

use uuid::Uuid;

/// Default rotation deadline (per client slot) baked into the wire event.
///
/// Tuned to dominate one WAN round-trip + envelope-build cost on a 20-
/// member group while staying short enough that a leader crash does not
/// leave the group visibly wedged. The client treats this as the time
/// it must wait before stepping to the next fallback position; a
/// genuinely-online leader will have committed the rotation (and emitted
/// `group_key_rotated`) well inside the window.
pub const DEFAULT_ROTATION_DEADLINE_MS: u32 = 7_500;

/// Outcome of [`elect_rotation_leader`].
///
/// Holds the elected leader and the ordered fallback list. The fallback
/// list does NOT include the leader (the leader is its own slot 0 in the
/// client's combined view); a downstream caller assembling the wire event
/// can read both fields directly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RotationLeader {
    pub leader: Uuid,
    pub fallback_order: Vec<Uuid>,
}

/// Pick the rotation leader from a snapshot of currently-online members.
///
/// Returns `None` when the snapshot is empty — no online member means no
/// candidate to fire the rotation. The handler logs and defers in that
/// case; the trigger will be re-emitted when any member reconnects (a
/// follow-up — today the deferred-trigger queue does not yet exist).
///
/// Selection rule: **lowest `user_id` first**. UUIDs are 128-bit, so
/// ordering by the natural `Uuid` `Ord` is total and reproducible across
/// runs. The choice is arbitrary — what matters is that every recipient
/// of the event sees the same ordering. Using a property the server can
/// compute without consulting any client (lowest of a globally-unique
/// ID) gives us that for free.
///
/// The returned `fallback_order` is the remaining online members sorted
/// ascending by `Uuid`. Clients walk it after `deadline_ms`-staggered
/// waits.
pub fn elect_rotation_leader(online_members: &[Uuid]) -> Option<RotationLeader> {
    if online_members.is_empty() {
        return None;
    }
    let mut sorted: Vec<Uuid> = online_members.to_vec();
    sorted.sort();
    // Deduplicate in case the caller handed us repeated entries (e.g. a
    // multi-device user with 3 connections — the leader is per-user, not
    // per-device). The sort above puts duplicates adjacent so dedup is O(n).
    sorted.dedup();
    let leader = sorted.remove(0);
    Some(RotationLeader {
        leader,
        fallback_order: sorted,
    })
}

/// Snapshot the online subset of `members` against `is_online`. The
/// resulting slice preserves whatever filter order the caller gives us
/// — sorting happens inside [`elect_rotation_leader`]. Extracted so the
/// handler can compose `members + Hub::device_count`-driven online check
/// without inlining the loop, and so tests can stub `is_online` with a
/// closure instead of constructing a real `Hub`.
pub fn online_subset<F>(members: &[Uuid], is_online: F) -> Vec<Uuid>
where
    F: Fn(&Uuid) -> bool,
{
    members.iter().copied().filter(|m| is_online(m)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Uuid {
        Uuid::parse_str(s).unwrap()
    }

    #[test]
    fn elects_lowest_uuid_as_leader() {
        let a = u("00000000-0000-0000-0000-000000000001");
        let b = u("00000000-0000-0000-0000-000000000002");
        let c = u("00000000-0000-0000-0000-000000000003");

        let got = elect_rotation_leader(&[c, a, b]).expect("at least one member");
        assert_eq!(got.leader, a);
        assert_eq!(got.fallback_order, vec![b, c]);
    }

    #[test]
    fn fallback_is_sorted_ascending_and_excludes_leader() {
        let ids: Vec<Uuid> = (1u128..=5)
            .map(|n| Uuid::from_u128(0xdead_beef_0000_0000_0000_0000_0000_0000 + n))
            .collect();
        // Shuffle the input — the implementation must not depend on caller order.
        let mut input = ids.clone();
        input.reverse();
        let got = elect_rotation_leader(&input).expect("non-empty");
        assert_eq!(got.leader, ids[0]);
        assert_eq!(got.fallback_order, ids[1..].to_vec());
    }

    #[test]
    fn single_online_member_has_empty_fallback() {
        let only = u("00000000-0000-0000-0000-000000000042");
        let got = elect_rotation_leader(&[only]).expect("one member");
        assert_eq!(got.leader, only);
        assert!(got.fallback_order.is_empty());
    }

    #[test]
    fn empty_snapshot_returns_none() {
        assert!(elect_rotation_leader(&[]).is_none());
    }

    #[test]
    fn deduplicates_repeated_user_ids() {
        // The Hub keys connections per (user_id, device_id); if a future
        // refactor accidentally passes the per-connection list instead
        // of the per-user list, the election must still produce a sane
        // leader rather than duplicating slots.
        let a = u("00000000-0000-0000-0000-000000000001");
        let b = u("00000000-0000-0000-0000-000000000002");
        let got = elect_rotation_leader(&[a, b, a, b, a]).expect("non-empty");
        assert_eq!(got.leader, a);
        assert_eq!(got.fallback_order, vec![b]);
    }

    #[test]
    fn online_subset_filters_offline_members() {
        let a = u("00000000-0000-0000-0000-000000000001");
        let b = u("00000000-0000-0000-0000-000000000002");
        let c = u("00000000-0000-0000-0000-000000000003");
        let online = online_subset(&[a, b, c], |id| *id != b);
        assert_eq!(online, vec![a, c]);
    }

    #[test]
    fn online_subset_with_nobody_online_yields_empty() {
        let a = u("00000000-0000-0000-0000-000000000001");
        let b = u("00000000-0000-0000-0000-000000000002");
        let online = online_subset(&[a, b], |_| false);
        assert!(online.is_empty());
        assert!(elect_rotation_leader(&online).is_none());
    }

    #[test]
    fn default_deadline_is_documented_value() {
        // Locked at 7.5s in the design doc; bumping it is a wire-format
        // change in spirit even though the field is just a hint. Any
        // change should land with a docs update — this assert is here
        // to make sure that pairing doesn't drift silently.
        assert_eq!(DEFAULT_ROTATION_DEADLINE_MS, 7_500);
    }
}
