# 04 — Migration Plan

How to get from today's `GRP1:` half-wired state to the recommended `GRP2:` end state without breaking the small number of production groups already running with `is_encrypted=true`.

## Pre-requisites (do NOT start until these are done)

These are the audit's two P0 items. Both must be in production before any group E2E work begins; without them, group E2E will inherit the same message-loss surfaces.

1. **P0-1**: keyring-lock-failure surfacing (`crypto-audit/06-recommendations.md` → P0-1). Group decrypt failures will hit this exact code path with a much wider blast radius — every recipient of a group message hits it, not just one.
2. **P0-2**: OTP-heal retry + alarm (`crypto-audit/06-recommendations.md` → P0-2). Group rotation involves the same fire-and-forget upload pattern; same fix applies.

## Phase 1 — Server-side ciphertext-only enforcement (#591)

**Goal**: make it impossible for a buggy client to send plaintext into an `is_encrypted=true` group.

- One PR. Server-only. Adds the structural validator from [`03-recommended-protocol.md`](03-recommended-protocol.md) §"Server-side enforcement".
- Rolled out in **shadow mode first** (log violations, don't reject) for 1 week so we can detect non-malicious clients still emitting plaintext.
- Then flip the rejection flag.

Estimate: 2 days code + 1 week shadow soak.

## Phase 2 — GRP2 wire format (client + server)

**Goal**: support GRP2 alongside GRP1. Senders default to GRP2; receivers accept both.

- One PR. Adds the GRP2 packer/unpacker in `group_crypto_service.dart`. Adds Ed25519 sender signature.
- Server changes: none. The server already treats group messages as opaque blobs.
- All existing-version envelopes remain GRP1; new key versions are GRP2.

Backward compat strategy:
- A receiver sees a GRP1 wire → decrypts as today.
- A receiver sees a GRP2 wire → verifies signature, then decrypts.
- A sender that hasn't been updated yet still emits GRP1; updated peers transparently consume it.

Estimate: 3–4 days code, including tests and the cross-implementation wire-compat vectors (also closes P2-2 from the audit).

## Phase 3 — Deterministic leader election for rotation (#658)

**Goal**: rotation completes reliably with one online member.

- One PR. Adds the `leader = members[hash(...) mod N]` ordering + staggered backoff.
- Requires server to emit `trigger_event_id` on every membership-change / rotate-request event. Small server change.
- Tests: an integration test that simulates all-online, leader-only-online, follower-only-online, and split-brain (two leaders elected by inconsistent member views). The last one is the interesting case — we want to confirm the UNIQUE-constraint tie-breaker behaves as the spec says.

Estimate: 4–5 days.

## Phase 4 — Recovery UX

**Goal**: when group decrypt fails, the user can act.

- One PR. Frontend-only.
- Adds two banners:
  - *"You can't decrypt this group's recent messages. Fetch the latest key?"* (action: re-fetch active key version).
  - *"Sender signature failed."* (no automatic action; user contacts admin).
- Adds a developer-mode log of group-decrypt events for forensic capture.

Estimate: 3 days.

## Phase 5 — Toggle defaults

**Goal**: new groups default to `is_encrypted=true`.

- Smallest PR. One flag flip in the create-group screen + the server-side default.
- Rolled out behind a feature flag for two weeks. Monitor: rate of group-decrypt failures, rate of rotation-completion latency, rate of `[Could not decrypt…]` placeholders.
- If metrics stay clean, default flip ships.

Estimate: 1 day code + 2 weeks soak.

## Rollback plan

Each phase is independently reversible:

- Phase 1: revert the enforcement; logs continue.
- Phase 2: receivers continue to accept GRP1; senders fall back if a fresh `is_encrypted=true` group is created on an older client (we never *delete* GRP1 support).
- Phase 3: revert leader-election; falls back to "everyone races" — same behaviour as today.
- Phase 4: revert banners; users see the old `[Could not decrypt…]` placeholder.
- Phase 5: flip the default off; existing encrypted groups keep working.

There is no destructive irreversible step in the plan. **This is deliberate** and the design's response to the user's "I fear losing user messages" framing.

## Total calendar estimate

Single engineer, no parallelisation:

- Pre-reqs (audit P0-1 + P0-2): ~3 days.
- Phase 1: 2 days code + 1 week soak.
- Phase 2: 4 days.
- Phase 3: 5 days.
- Phase 4: 3 days.
- Phase 5: 1 day code + 2 weeks soak.

**~3 weeks of work + ~3 weeks of soak time** = roughly 6 weeks calendar to default-on group E2E.

## What we are *not* committing to

- A date. The calendar above assumes nothing else lands; in reality, other features compete.
- Default-on for *existing* groups. Migration of plaintext groups to encrypted is a separate design problem — moving a multi-year message history through key versioning is not free. Out of scope here.
- MLS. We chose Sender Keys-style in [`02-protocol-options.md`](02-protocol-options.md). If product priorities later move toward 200+-member groups, we revisit then.
