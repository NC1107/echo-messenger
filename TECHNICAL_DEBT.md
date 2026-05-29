# Technical Debt — Echo Messenger

Captured from the 2026-05-20 multi-agent audit of the 26 PRs (#980–#1005) shipped on the same day. The mechanical / low-risk items were applied in the audit follow-up PR; this file tracks the remaining work that needed design judgment, larger refactors, or test infrastructure beyond a single follow-up commit.

Audit baseline commit range: `628e623ebd6108b230f313ccebdcb922e6f09e3d^..HEAD` (40 files, +1838/-756 lines). 6 reviewers ran in parallel (code-quality, security, performance, frontend, backend, test-coverage). ~66 findings total; 3 critical, 11 high, 28 medium, 24 low. Convergent risk across all reviewers: the rotation-storm on `member_added` and the lack of single-flight in self-heal — partially addressed in the follow-up PR with a per-conversation in-flight set, but the parallel identity-key fetch optimization remains.

Last updated: 2026-05-25 (after high-tier batch shipped).

## Summary

**2026-05-20 batch (TD-1..TD-23):**
- Critical / High remaining: 0  (TD-1..TD-4 shipped in PR #1007)
- Medium remaining: 1  (TD-14 — conversation Map index; deferred)
- Low remaining: 2  (TD-20 partial schema migration, TD-23 harder test surfaces)

The medium/low cleanup batch landed across server + client + tests (TD-5..TD-13, TD-15..TD-19, TD-21, TD-22, partial TD-23).

**2026-05-25 fresh-eyes audit (TD-24..TD-85):**
- Critical: 0 remaining (TD-24..TD-27 shipped — JWT device revocation, range-read DoS, reset_password tx, reset-token log leak).
- High remaining: 1 partial (TD-28 rotation-path rollout) — TD-29..TD-42 all shipped in the same session.
- Medium remaining: 25  (TD-43..TD-67; routes, perf, client componentization debt)
- Low remaining: 18  (TD-68..TD-85; many small one-liners batched for a single cleanup PR)

Audit baseline: main @ de37839b. Five parallel reviewers (security, backend, frontend, performance, test-quality) verified actual code — CLAUDE.md/docs deliberately ignored. Full per-finding evidence (file:line + code quote) lives in `.claude/state/audit-2026-05-25.md`.

---

## Critical / High — RESOLVED in PR #1007

### TD-1 — Parallel identity-key fetch in `performRotation` ✅ shipped
**File:** `apps/client/lib/src/services/group_crypto_service.dart:695`
**Severity:** high
**Source:** performance, frontend, security reviewers
**What:** `performRotation` fetched each member's identity key serially in a for-loop.
**Shipped:** `Future.wait` parallelises the N fetches; wall time collapses from O(N) RTTs to roughly one. A future server-side batch endpoint would further cut it to a single request.

### TD-2 — Server gate: validate creator has keys before `is_encrypted=true` ✅ shipped
**File:** `apps/server/src/routes/groups/create.rs:42-50`
**Severity:** medium (rated up because of cascading wedge risk)
**Source:** backend reviewer
**What:** A malicious or buggy client could `POST /api/groups` with `is_encrypted=true` even without published prekeys, permanently bricking the conversation.
**Shipped:** `db::keys::has_publishable_keys` runs an EXISTS check; the route returns 400 with a friendly message when the caller hasn't completed key setup.

### TD-3 — Transactional consistency of group creation ✅ shipped
**File:** `apps/server/src/routes/groups/create.rs:54-76`
**Severity:** high
**Source:** backend reviewer
**What:** `create_group_with_visibility` committed its own tx; two `create_channel` calls then ran outside any tx, leaving orphan groups on partial failure.
**Shipped:** Channel inserts moved inside `create_group_with_visibility`; the group + member + channel inserts all share one tx.

### TD-4 — TOFU bypass in group key rotation silently trusts changed identity keys ✅ shipped
**File:** `apps/client/lib/src/services/crypto/peer_identity_extension.dart:22-44` (consumed at `apps/client/lib/src/providers/crypto_provider.dart:486-489`, `ws_handlers/crypto_handlers.dart:144`)
**Severity:** high
**Source:** security reviewer
**What:** `forceRefresh=true` bypassed the TOFU cache; the new server-fetched key was wrapped into the rotation envelope without checking whether the key had changed since first contact. A compromised server could substitute a key the user has never confirmed.
**Shipped:** `performRotation` now accepts a `hasIdentityKeyChanged` callback. After the parallel identity-key fetch, the rotation calls the checker per user and aborts when any TOFU flag is set. Both rotation call sites pass the checker. Follow-up (deferred): explicit admin confirm UI to acknowledge the change and resume rotation.

---

## Medium — outstanding

### TD-5 — Self-heal in `sendGroupMessage` lacks explicit refetch on 409
**File:** `apps/client/lib/src/providers/websocket_provider.dart:593-622`
**What:** When `seedInitialGroupKey` returns `null` from losing a 409 race, the follow-up `getGroupKey` may still see an empty local cache. Send fails; user retries; self-heal fires again.
**Fix:** After `seedInitialGroupKey` returns null, call `groupCrypto.fetchGroupKey(conversationId)` explicitly to pull the winning rotation before falling through to `_addFailedMessage`. **Effort:** small.

### TD-6 — TOCTOU race in version probe
**File:** `apps/client/lib/src/providers/crypto_provider.dart:428-437`
**What:** Between the GET `/keys/latest` probe and the POST rotation, another client can bump the version. The POST 409s and the caller returns `null` without refetching.
**Fix:** Accept an optional `currentVersion` parameter so callers with a fresh hint (e.g. WS `group_key_rotation_requested`) can skip the probe. On 409, refetch explicitly. **Effort:** small.

### TD-7 — `is_encrypted` lacks server-side immutability guard
**File:** `apps/server/src/routes/groups/types.rs:14-20`, `apps/server/src/routes/groups/settings.rs`
**What:** Today `UpdateGroupRequest` doesn't include `is_encrypted`, so it can't be flipped post-creation. But there's no defense-in-depth: a future contributor could trivially add it and silently allow a downgrade attack.
**Fix:** Add a code comment in `types.rs` locking down the intent and a compile-time test asserting `UpdateGroupRequest` has no `is_encrypted` field. Optionally add a DB trigger preventing the column from being changed from `true` to `false`. **Effort:** small.

### TD-8 — `is_encrypted` not returned in `GroupInfo`
**File:** `apps/server/src/db/groups.rs:62-72`
**What:** The INSERT doesn't RETURN `is_encrypted` so the response object after group creation has no encryption indicator. Clients must round-trip a GET to confirm encryption was actually enabled.
**Fix:** Add `is_encrypted` to both the RETURNING clause and the `GroupInfo` struct, surface it on `GroupResponse`. **Effort:** small.

### TD-9 — Channel-create runs outside group-create tx (see TD-3)
Tracked above. Same finding from a different reviewer.

### TD-10 — Conversation tile ListView missing keys
**File:** `apps/client/lib/src/screens/home_screen.dart:758`
**What:** ListView.builder over conversations builds no `key` on items. With the Stack + conditional selection pill wrapping each row, element recycling can briefly bind to the wrong conversation after a reorder (flash wrong avatar).
**Fix:** Wrap returned Padding in `KeyedSubtree(key: ValueKey(conv.id), ...)`. **Effort:** small.

### TD-11 — VoiceDock hardcoded width: 320 inside flex column
**File:** `apps/client/lib/src/widgets/conversation_panel.dart:566`
**What:** Dock takes a hardcoded 320px in a column that can be a different width when the sidebar is collapsed / resized.
**Fix:** Drop the width argument; let the dock take `double.infinity` from the column, or pass through `LayoutBuilder` constraints. **Effort:** small.

### TD-12 — `didChangeDependencies` in avatar cropper mutates state without `setState`
**File:** `apps/client/lib/src/widgets/avatar_crop_dialog.dart:144-168`
**What:** Mutates `_previewSize`, `_scale`, `_offset` outside the `setState` cycle. Follow-up build runs but the mutation races with concurrent setStates from the async decode.
**Fix:** Wrap the mutation in `setState`. Optionally compute breakpoint via `LayoutBuilder` for a declarative path. **Effort:** small.

### TD-13 — Avatar cropper Slider min/max recomputed every build
**File:** `apps/client/lib/src/widgets/avatar_crop_dialog.dart:371-389`
**What:** Slider `min` and the value clamp recompute the min-scale formula on every paint, including during drag ticks.
**Fix:** Cache `_minScale` field updated only in `_decodeImage` + the breakpoint-flip branch. **Effort:** small.

### TD-14 — `_maybeRotateOnJoin` linear scans on every member_added
**File:** `apps/client/lib/src/providers/ws_handlers/presence_handlers.dart:108-118`
**What:** Two `.where(...).firstOrNull` scans on full conversation list + full member list per event. WS event path; high-frequency.
**Fix:** Add a `Map<String, Conversation>` index to `conversationsProvider`; denormalize local user role onto `Conversation`. **Effort:** medium.

### TD-15 — Group name length cap uses byte count, not char count
**File:** `apps/server/src/routes/groups/create.rs:23-27`
**What:** `body.name.len() > 100` counts bytes. A single emoji is 4 bytes; CJK characters are 3 bytes. Users get inconsistent feedback.
**Fix:** Use `body.name.chars().count()` or document the byte cap explicitly. Also `trim()` before the empty check. **Effort:** small.

---

## Low — outstanding

### TD-16 — Missing barrierLabel on quick-switcher / global-search / shortcuts dialogs
**File:** `apps/client/lib/src/screens/home_screen.dart:377-407`
**What:** Backdrop dim was bumped to `Colors.black54` in PR #988, making the modal layer perceptible. Screen readers announce a generic "dismiss" because no `barrierLabel` was set.
**Fix:** Add `barrierLabel: 'Dismiss <surface>'` to all three. **Effort:** small.

### TD-17 — `_deleteGroup` doesn't deselect the active conversation
**File:** `apps/client/lib/src/widgets/conversation_panel.dart:409+`
**What:** After successful delete the user remains on the stale chat panel until the provider rebuild fires.
**Fix:** Call `widget.onConversationSelected?.call(null)` (or equivalent) immediately on success. Also fix the `convs.isNotEmpty` guard in `_syncSelectedConversation` to handle the last-conversation-deleted case. **Effort:** small.

### TD-18 — Probe error swallow could mask auth failures (partially addressed)
The audit follow-up PR now logs the failure. Open follow-up: distinguish 401/403 from 404 explicitly so the rotation can abort vs proceed with `version=1`.

### TD-19 — E2E spec accidentally runnable against prod
**File:** `tests/e2e/group_encryption_roundtrip.spec.ts:22-31`
**What:** `process.env.ECHO_SERVER` default of `localhost:8080` is safe, but a developer with `ECHO_SERVER=https://echo-messenger.us` exported in their shell would unintentionally run the round-trip against prod when they invoke `--project=maintained`.
**Fix:** Add `test.skip(... !!process.env.ECHO_SERVER?.includes('echo-messenger.us') && process.env.ALLOW_PROD_ROUNDTRIP !== '1', ...)`. **Effort:** small.

### TD-20 — Duplicate-name check is read-then-write race
**File:** `apps/server/src/routes/groups/create.rs:30-40`
**What:** `user_has_public_group_named` returning false then the insert is not atomic. Concurrent requests can race and both succeed.
**Fix:** Unique partial index + map `23505` to 409 in `DbErrCtx`. **Effort:** medium.

### TD-21 — `getIdentityPublicKey()` returning null silently omits self
**File:** `apps/client/lib/src/providers/crypto_provider.dart:483-487`
**What:** If the keyring is locked, `getIdentityPublicKey()` returns null. The for-loop in `performRotation` skips self silently, so the rotator uploads envelopes that exclude themselves — they can't decrypt their own group messages until the next rotation re-includes them.
**Fix:** When the self key is null, abort the whole rotation with a "keyring locked" error. **Effort:** small.

### TD-22 — `seedInitialGroupKey` reverse-list arrow direction is fragile
**File:** `apps/client/lib/src/widgets/chat_input_bar.dart:1496` (now ~1505 after the audit follow-up)
**What:** ArrowDown passes `delta=-1` because the picker uses `reverse: true`. A maintainer reading the code is likely to "fix" the sign.
**Fix:** Introduce a `kDown = -1` constant or take a semantic direction enum so the inversion is named. **Effort:** small.

### TD-23 — Test coverage gaps from new code
Five untested surfaces from PR-batch:
- `_maybeRotateOnJoin` (role/encrypted guards) — `apps/client/lib/src/providers/ws_handlers/presence_handlers.dart:94-128`
- `OwnDecryptFailedBubble` widget — `apps/client/lib/src/widgets/message/message_indicators.dart:151+`
- `MessageItem` own-message → `OwnDecryptFailedBubble` branch — `apps/client/lib/src/widgets/message_item.dart`
- `MentionAutocomplete.candidateValues` static helper
- `_moveMentionSelection` wrap-around (off-by-one prone)

Each test sketched in the test-coverage reviewer's findings. **Effort:** medium total.

---

## Already addressed

### PR #1006 (initial audit follow-up)
- ✅ Rotation-storm single-flight per conversation in `seedInitialGroupKey` (critical)
- ✅ Cached `_mentionCandidates` (no allocation per keystroke)
- ✅ Logged probe failure in `seedInitialGroupKey`
- ✅ Removed double `markShown()` call in WhatsNewInlineOverlay
- ✅ Replaced AnimatedContainer with Container in debug log row + RepaintBoundary
- ✅ Deleted `_presenceStatus` dead field + unreachable `setPresenceStatus` branch
- ✅ Deleted `MentionCandidate` dead class
- ✅ Server-side length caps: `encrypted_key` ≤ 512 bytes, `triggered_by_event` ≤ 128 chars

### PR #1007 (high-tier batch)
- ✅ **TD-1** Parallel identity-key fetch in `performRotation` (`Future.wait`)
- ✅ **TD-2** Server gate refuses `is_encrypted=true` without published keys
- ✅ **TD-3** Channels seeded inside the group-create transaction
- ✅ **TD-4** Rotation aborts when any participant's TOFU flag is set

## Progress tracking
- [x] TD-1 parallel identity-key fetch — PR #1007
- [x] TD-2 server gate on `is_encrypted=true` — PR #1007
- [x] TD-3 / TD-9 channel-create in tx — PR #1007
- [x] TD-4 TOFU bypass detection — PR #1007
- [x] TD-5 explicit refetch on 409 — cleanup batch
- [x] TD-6 TOCTOU version probe (optional currentVersion param) — cleanup batch
- [x] TD-7 `is_encrypted` immutability guard (doc + compile-test) — cleanup batch
- [x] TD-8 return `is_encrypted` in `GroupInfo` — cleanup batch
- [x] TD-10 ListView keys on conversation tiles — cleanup batch
- [x] TD-11 VoiceDock width via LayoutBuilder — cleanup batch
- [x] TD-12 setState in didChangeDependencies — cleanup batch
- [x] TD-13 Slider min cache — cleanup batch
- [ ] TD-14 Map index for conversations + denormalized role — deferred (needs conv-provider refactor)
- [x] TD-15 char-count name length — cleanup batch
- [x] TD-16 barrierLabel on dialogs — cleanup batch
- [x] TD-17 deselect after delete (isLoading gate) — cleanup batch
- [x] TD-18 distinguish 401/403/404 in probe — cleanup batch
- [x] TD-19 prod-skip guard on E2E spec — cleanup batch
- [ ] TD-20 unique index for public-group names — deferred (needs schema migration)
- [x] TD-21 abort rotation when self key null — cleanup batch
- [x] TD-22 semantic direction enum (`_MentionMove`) — cleanup batch
- [~] TD-23 test coverage — 2 of 5 surfaces covered (MentionAutocomplete.candidateValues, OwnDecryptFailedBubble); remaining (_maybeRotateOnJoin, _moveMentionSelection wrap, conversation_item mask) need Riverpod test harness scaffolding

---

# 2026-05-25 fresh-eyes audit

Multi-agent deep review of the actual codebase, docs deliberately ignored. Convergent findings (multiple reviewers flagged independently) marked ★. The four critical items shipped in this commit; everything else is open.

## Critical — RESOLVED in this commit

### TD-24 ★ — Password-reset tokens written verbatim into `tracing::info!` ✅ shipped
**File:** `apps/server/src/routes/auth.rs:485-498`
**Source:** security, backend (both flagged independently)
**What:** `tracing::info!(... token = %token, ...)` made any log aggregator a 15-minute account-takeover oracle outside the auth boundary. Doc-comment acknowledged the risk but shipped anyway.
**Shipped:** Token field dropped from the log line. Operators read the reset row from `password_reset_tokens` directly and deliver out-of-band. The full SMTP/admin-mediated relay redesign is still a follow-up.

### TD-25 — `reset_password` now transactional ✅ shipped
**File:** `apps/server/src/routes/auth.rs:516-558`
**Source:** backend
**What:** Three separate writes (`update_password`, `consume_token`, `revoke_all_user_tokens`) with no tx — a failure between writes left the token unused and replayable.
**Shipped:** All three writes share one `state.pool.begin()` transaction. `db::password_reset::*`, `db::users::update_password`, and `db::tokens::revoke_all_user_tokens` were widened to accept `impl sqlx::PgExecutor<'_>` so they bind to either `&PgPool` or `&mut *tx`.

### TD-26 — Byte-range download streams instead of allocating ✅ shipped
**File:** `apps/server/src/routes/media.rs:560-592`
**Source:** backend
**What:** `serve_byte_range` did `vec![0u8; slice_len]` + `read_exact` against a `slice_len` capped only at `MAX_FILE_SIZE = 100 MB`. A single request could pin 100 MB; N concurrent requests trivially OOM-killed the server.
**Shipped:** Replaced with `ReaderStream::new(file.take(slice_len))` after `seek`. Memory cost is now O(buffer-size), independent of `Range` header.

### TD-27 — JWT auth now honors device-revocation events ✅ shipped
**File:** `apps/server/src/auth/middleware.rs:18-58`, `apps/server/src/auth/invalidation.rs` (new)
**Source:** backend
**What:** `AuthUser` validated only `iss`/`aud`/`exp`. A stolen or revoked-device JWT continued to authorize every REST endpoint for the full 15-minute TTL even after `revoke_device` / `revoke_other_devices` / `change_password` / `reset_password` / `logout`.
**Shipped:** New `TokenInvalidator` (in-memory DashMap<UserId, min-iat-floor>) wired into `AppState`. `AuthUser` rejects JWTs with `iat < floor` and returns `TokenRevoked`. The six revocation paths (revoke_device, revoke_other_devices, reset_device, change_password, reset_password, logout) call `state.token_invalidator.invalidate(user_id)`. 4 unit tests pin behavior; 27 keys + 20 auth + 1 race integration tests still pass.

**Trade-off:** in-memory only. A server restart re-allows tokens up to their 15-minute TTL — same window we already accept today, and avoids a per-request DB lookup. Adding `device_id` to JWT claims and per-device revocation lookups is left as a follow-up if we ever ship multi-server replicas.

---

## High — outstanding

### TD-28 ★ — Group-key envelopes are unsigned; rotator identity not bound — primitives landed (2026-05-25), rollout pending
**File:** `apps/client/lib/src/services/crypto_service.dart` (encryptForUserSigned / decryptFromUserVerified), server accept in `apps/server/src/routes/group_keys.rs:335`
**Source:** security
**What:** ECIES wrap with no Ed25519 signature. A compromised server or racing admin can publish envelopes wrapping a key the operator controls; receivers unwrap, cache, and start encrypting with it. GRP2 added per-message signatures but the key-distribution layer remains MAC-only. The design proposal already flags this in `docs/group-e2e-design/06-open-questions.md`.
**Shipped (2026-05-25):** `encryptForUserSigned` + `decryptFromUserVerified` primitives append/verify a 64-byte Ed25519 signature over the existing ECIES wrap. Three unit tests cover happy-path round-trip, signature-mismatch rejection, and tamper detection. Wire prefix is unchanged (legacy unsigned envelopes still parse via `decryptFromUser`).
**Still open (rollout):** plumb the primitives into the rotation path. Needs `group_key_envelopes.created_by_user_id` (or derive via `group_key_rotations.triggered_by_user_id`) so the recipient knows which rotator's signing key to verify against, plus client-side migration window that accepts both signed and unsigned envelopes during the cutover. **Effort:** medium (schema migration + server route changes + client cutover gate).

### TD-29 — TOFU silently overwrites changed peer identity key
**File:** `apps/client/lib/src/services/crypto/peer_identity_extension.dart:59-87`
**Source:** security
**What:** Sets a "changed" flag but writes the new key to the cache anyway. The DM session-establishment path checks the flag (`IdentityKeyChangedException`); the group-rotation path, safety-number screen, and other `fetchPeerIdentityKey` consumers read the freshly-written key without checking. A user who hasn't opened the DM with the swapped peer silently wraps a group key for the attacker.
**Fix:** Keep the old key canonical until explicit `acceptIdentityKeyChange`; expose pending key only via opt-in getter for code paths that legitimately need it (key reset flow).
**Effort:** small.

### TD-30 ★ — `recipient_device_contents` doesn't require peer inclusion
**File:** `apps/server/src/ws/message_service/fanout.rs:162-200` + `validate.rs:249-291`
**Source:** security
**What:** For encrypted DMs the validator requires a non-empty per-device map but doesn't require the actual conversation peer to appear. `deliver_to_member` silently falls back to `legacy_msg` when the recipient is missing — letting a sender deliver attacker-shaped bytes to the peer while routing the real ciphertext to their own devices.
**Fix:** For encrypted-DM kinds, require `recipient_device_contents` to include every non-sender member. Reject the send otherwise.
**Effort:** small.

### TD-31 — `link_preview` SSRF block-list incomplete
**File:** `apps/server/src/routes/link_preview.rs:79-115` (and rate_limit.rs:310-322 has a similar gap)
**Source:** security, backend
**What:** Missing CGNAT (100.64.0.0/10), 192.0.0.0/24, 198.18.0.0/15 (benchmark), TEST-NETs, 224.0.0.0/4, broadcast. No port allowlist. Also uses blocking `to_socket_addrs` in an async handler.
**Fix:** Use the `ipnet` crate (already a dep) with a comprehensive CIDR deny list. Port allowlist `{80, 443}`. Switch DNS to `tokio::net::lookup_host`.
**Effort:** 1 h.

### TD-32 — IPv4-mapped IPv6 not normalized for rate-limit XFF
**File:** `apps/server/src/middleware/rate_limit.rs:310-322`
**Source:** security
**What:** `is_private` IPv6 branch ignores `to_ipv4_mapped()`. A trusted proxy that passes `::ffff:10.0.0.1` lets an attacker pick the bucket key.
**Fix:** Normalize via `to_ipv4_mapped()` and apply the v4 private-range check on the mapped address.
**Effort:** small.

### TD-33 — Group member mutation lacks tx + duplicate member-list fetch
**File:** `apps/server/src/routes/groups/members.rs:147-264, 267-316, 319-367` (and `groups/invite.rs:238, 270`)
**Source:** backend, performance
**What:** `add_member` / `remove_member` / `ban_member` run 6-8 sequential queries with no transaction and no `FOR UPDATE` — two concurrent admins acting on the same target can both pass the guard reads and both mutate. `get_conversation_member_ids` is called twice in the success path.
**Fix:** Wrap in `pool.begin()` with `SELECT ... FOR UPDATE` on the caller's `conversation_members` row. Fetch member ids once, reuse for both broadcasts.
**Effort:** 2-3 h.

### TD-34 — HTTP status code drift (401 vs 403 vs 404)
**Files:** `routes/groups/members.rs:175,281,332,382` (permission → 401); `error.rs:162-181` (`NotMember` → 401); `routes/messages.rs:414,465,482` (not-found → 400); `routes/users.rs:81,103,146,560`; `routes/keys.rs:330,360`.
**Source:** backend
**What:** Permission failures return 401, triggering client global re-auth instead of "forbidden". "Not found" cases return 400, defeating client retry semantics.
**Fix:** Re-map `NotMember` → 403; convert 400-not-found cases to 404; convert permission 401s to 403. Update fixture tests in the same PR.
**Effort:** half day.

### TD-35 — WS voice/canvas signals accept unbounded `serde_json::Value`
**File:** `apps/server/src/ws/protocol.rs:49-55, 65-70`
**Source:** backend
**What:** Inner JSON only bounded by the 64 KB frame cap; voice signals fire per ICE candidate, canvas events per stroke point. Bandwidth amplification × N members.
**Fix:** Typed enums (`IceCandidate { sdp: String }`, etc.) with bounded field lengths.
**Effort:** 1 day.

### TD-36 — WS rate-limit message counter not decremented on Ping/Binary
**File:** `apps/server/src/ws/rate_limit.rs:213-234`
**Source:** backend
**What:** `handle_other_frame` only updates the byte budget. Zero-byte Pings escape the message-count cap — an attacker can flood 1000 Pings/sec with no slowdown.
**Fix:** Decrement `bucket.tokens -= 1.0` for all frame types.
**Effort:** 15 min — highest impact-per-effort remaining.

### TD-37 — Cleanup tasks + push fanout have no shutdown coordination
**File:** `apps/server/src/main.rs:43-110, 125-141`
**Source:** backend
**What:** Fire-and-forget `tokio::spawn`s for periodic cleanups and push fanout. `with_graceful_shutdown` only stops the HTTP server, not the background tasks. SIGTERM during a `cleanup_expired_messages` mid-DELETE is torn at an arbitrary instruction.
**Fix:** `tokio_util::sync::CancellationToken` for periodic loops (`select!` on `token.cancelled()`); `tokio::task::JoinSet` for one-shot spawned work, awaited on shutdown.
**Effort:** 2-3 h.

### TD-38 — `reset_device` not transactional
**File:** `apps/server/src/routes/keys.rs:608-664`
**Source:** backend
**What:** `clear_device_fingerprint` then `revoke_device` — two separate DB round-trips. Crash in between leaves the device with cleared fingerprint but extant identity_keys row; next bundle upload may rebind to a different identity silently.
**Fix:** Wrap in a single tx.
**Effort:** 30 min.

### TD-39 — No HTTP caching headers on avatars / media
**File:** `apps/server/src/routes/users.rs:730-775`, `routes/media.rs::download`
**Source:** backend, performance
**What:** Every chat-list render = 50 avatar DB+disk reads. No `Cache-Control` / `ETag` → CDN can't cache.
**Fix:** `Cache-Control: public, max-age=300, stale-while-revalidate=86400`; weak `ETag` from `(file_uuid, mtime)`; honor `If-None-Match` → 304.
**Effort:** 1 h.

### TD-40 — OTP atomicity has no concurrency test
**File:** `apps/server/tests/api_keys.rs`
**Source:** test-quality
**What:** 27 tests, zero use `tokio::spawn`/`join!`. The invite-link race got the same-shape race-test treatment; OTP did not. `get_bundle` does select+delete of a one-time prekey — two concurrent X3DH initiations could race.
**Fix:** Spawn N+1 concurrent `GET .../bundle?device_id=0`; assert returned `key_id`s are unique and final OTP count is 0; assert the (N+1)th returns `one_time_prekey: null` without panicking.
**Effort:** ~60 LoC, mirror `concurrent_accept_respects_max_uses_under_lock`.

### TD-41 — WS rotation storm has no integration test
**File:** `apps/server/src/ws/rotation.rs` + `apps/server/tests/ws_messaging.rs`
**Source:** test-quality
**What:** 8 pure-leader-election unit tests, no integration test opens N concurrent WebSockets to the same group and triggers a simultaneous rotation. That's the entire purpose of `rotation.rs`.
**Fix:** 5-WS-session test (3 members × 2 devices). Trigger two simultaneous rotations. Assert exactly one rotation envelope reaches each receiver; loser is dropped server-side; `group_keys` table has exactly one new version.
**Effort:** ~150 LoC.

### TD-42 — Refresh-token theft cascade only tested at depth 1
**File:** `apps/server/tests/api_auth.rs:106`
**Source:** test-quality
**What:** Replay test chains depth 1 only; `revoke_token_family` chain-revocation is never end-to-end verified for deeper chains.
**Fix:** Chain T0→T1→T2→T3, replay T0, assert T3 also 401 via `/refresh`.
**Effort:** ~40 LoC.

---

## Medium — outstanding

Compact list — full evidence (file:line + code quote) in `.claude/state/audit-2026-05-25.md`. All are open as of the 2026-05-25 audit.

### TD-43 — Refresh cookie `SameSite=None` with permissive default CORS
`apps/server/src/routes/auth.rs:39-50` + `routes/mod.rs:115-141`. Default `CORS_ORIGINS` includes `http://localhost:8081`; any malicious page there can chain a credentialed `/api/auth/refresh` to lock out the user. **Fix:** Origin-header check on `/refresh` and `/logout`; drop localhost from defaults.

### TD-44 — Admin first-user bootstrap is a permanent race
`apps/server/src/db/users.rs:51-65`. The first registration becomes admin via `(SELECT NOT EXISTS ...)`. **Fix:** Gate behind `ECHO_BOOTSTRAP_ADMIN_USERNAME`.

### TD-45 — No admin demotion endpoint + no audit log
`apps/server/src/routes/admin.rs:388-412`. Once promoted, only direct SQL can demote; no record of who promoted whom. Combined with TD-44, a single compromise is permanent. **Fix:** `DELETE /api/admin/promote/{user_id}` + `admin_audit` table.

### TD-46 — Media ticket bound to user only, not media-id
`apps/server/src/routes/media.rs:498-526` + `847-863`. 5-min reusable read for any media the user can access. **Fix:** Bind tickets to `(user_id, media_id)`; or accept a list of media IDs at issue time.

### TD-47 — `KeyReset` / `CallStarted` broadcasts use cached username from upgrade
`apps/server/src/ws/events/broadcast.rs:14-39`. Defense-in-depth gap; rename mid-session never surfaces. **Fix:** Re-fetch username per broadcast (or refresh on rename event).

### TD-48 — WS rate limiter is per-session, not per-user
`apps/server/src/ws/rate_limit.rs:240-264`. Consecutive-violation counter resets on reconnect. **Fix:** Process-wide DashMap keyed on user_id with slow decay; carry violations across reconnects.

### TD-49 — Argon2id uses library defaults
`apps/server/src/auth/password.rs:11`. `Argon2::default()` not pinned to explicit `m_cost`/`t_cost`/`p_cost`. The DUMMY_HASH at `auth.rs:210` is hardcoded against today's defaults — a dep bump that softens defaults breaks the timing-equalization too. **Fix:** Construct with explicit `Params::new(...)`.

### TD-50 — Refresh-token cookie XSS exfiltration via in-origin fetch
`apps/server/src/routes/auth.rs:42-50`. `HttpOnly` protects `document.cookie` reads, but any XSS on `web.echo-messenger.us` can fire `fetch('/api/auth/refresh', {credentials: 'include'})` and exfiltrate the rotated JSON. Theft detection only fires after one rotation. **Fix:** Independent — lock down web-build CSP via nginx; long-term consider IP/UA binding (mobile roaming caveat).

### TD-51 — `update_my_privacy` is non-transactional read-modify-write
`apps/server/src/routes/users.rs:95-133`. Two concurrent PATCHes from different devices lose fields. **Fix:** Single `UPDATE ... SET col = COALESCE($new, col)` per column; eliminate the pre-read.

### TD-52 — `cleanup_expired_messages` unpaginated + per-conversation N+1 broadcast
`apps/server/src/db/messages.rs:490-499` + `main.rs:297-315`. A backlog of 10k expirations triggers one giant DELETE and ~N member-list fetches. **Fix:** Cap DELETE with `LIMIT 500` loop; group broadcasts by conversation_id.

### TD-53 — `get_bundle` N+1 fallback for users without device_0 row
`apps/server/src/routes/keys.rs:316-330`. Up to 10 round-trips per fetch on multi-device users. **Fix:** Single query `ORDER BY device_id LIMIT 1`.

### TD-54 — `get_all_prekey_bundles` does one UPDATE per device
`apps/server/src/db/keys.rs:387-419`. Up to N writes per call (N = device count). **Fix:** Single `UPDATE ... WHERE id IN (...) RETURNING device_id, key_id, public_key` with `DISTINCT ON (device_id)` + `FOR UPDATE SKIP LOCKED`.

### TD-55 — `messages::get_messages` joins full-table `GROUP BY reply_to_id`
`apps/server/src/db/messages.rs:259-264` (also `search_messages:642`, `get_thread_replies:1018`). Aggregate set scales with all-messages in DB instead of the page. **Fix:** Scope aggregate via CTE to the same conversation/page batch, mirror `get_undelivered:392`.

### TD-56 — DB pool has no `min_connections` + short `acquire_timeout`
`apps/server/src/db/mod.rs:30-44`. Cold connections add 50-200 ms to bursts after idle; 5s acquire timeout converts pool exhaustion into 500s. **Fix:** `min_connections(5)`, `acquire_timeout(15s)`.

### TD-57 — No cleanup task for `password_reset_tokens`
`apps/server/src/routes/auth.rs:516-561` — tokens accumulate forever; combined with TD-25 (now fixed), abuse can grow the table. **Fix:** Add `spawn_periodic("password_reset_tokens", 600s, cleanup_expired_password_reset_tokens)`.

### TD-58 — Push notification fanout serial
`apps/server/src/push.rs:185-200`. 50-recipient group blocks the fanout task for 1.5-6 s of sequential APNs HTTP. **Fix:** `JoinSet` with bounded concurrency (~16) to respect APNs HTTP/2 connection limits.

### TD-59 — Sequential `session.encrypt` on UI thread
`apps/client/lib/src/services/signal_session.dart:150-180` called from `crypto_service.dart:775,788`. `decrypt` is on `compute()`; `encrypt` is not. `encryptForAllDevices` loop = 150 sequential KDF+AES rounds for a 50-member multi-device group → visible jank. **Fix:** Mirror decrypt — single isolate call wrapping the loop.

### TD-60 — `shared_media_gallery` watches whole `chatProvider`
`apps/client/lib/src/widgets/shared_media_gallery.dart:26`. Rebuilds on every message in every conversation. **Fix:** `.select((s) => s.messagesForConversation(conversationId))` — one-line.

### TD-61 — `build_per_device_json` deep-clones JSON `Value` per device
`apps/server/src/ws/message_service/fanout.rs:129-135`. 50-member × 2-device group = 100 deep clones per send. **Fix:** Serialize once with a sentinel for `content`, then string-replace per device.

### TD-62 — `feedback_dialog.dart` web-crash hazard
`apps/client/lib/src/widgets/feedback_dialog.dart:52` reaches `Platform.operatingSystem` without `kIsWeb` guard. **Fix:** `if (kIsWeb) return 'web';` early-return. **Note:** relevant to the uncommitted feedback_dialog edit currently in the working tree.

### TD-63 — Theme drift: `Colors.white` hardcoded across 16+ screens
`apps/client/lib/src/screens/{username_invite_screen,discover_groups_screen,user_profile_screen,onboarding_wizard,safety_number_screen,settings/account_section}.dart`. Breaks on any light theme with a light accent. **Fix:** Replace with `context.onAccent` / `colorScheme.onPrimary`.

### TD-64 — 8 inline `AlertDialog`s instead of `showEchoConfirmDialog`
`screens/user_profile_screen.dart:693`, `settings/account_section.dart:359`, `voice_lounge_screen.dart:562`, `settings/voice_section.dart:161`, `settings/about_section.dart:239`, `group_info_screen/parts/channels_section.dart:15`, `settings/privacy_section.dart:81`, `settings/advanced_theme_section.dart:266`. Drift risk on button order / destructive styling. **Fix:** Migrate to the shared helper.

### TD-65 — 6 hand-rolled `CircleAvatar`s instead of `UserAvatar`/`buildAvatar`
`settings/account_section.dart:451`, `group_info_screen/parts/header_section.dart:151,159`, `screens/join/join_preview_scaffold.dart:286,366,373`, `settings/accessibility_section.dart:79`. The account-section variant uses a raw `NetworkImage` that bypasses `chatMediaCacheManager` entirely.

### TD-66 — Migration test asserts only count > 0
`apps/server/tests/migrations.rs:73-80`. A migration with wrong column type / missing NOT NULL passes. 48 migrations in tree vs CLAUDE.md's stale "14" claim. **Fix:** Snapshot `information_schema.{tables,columns}` for ~10 critical columns.

### TD-67 — `core/rust-core` has only 53 tests total
13 for ratchet, 4 for x3dh, 2 for grp2 — thin for a "reference" implementation. Add ratchet edge-case coverage (MAX_SKIP overflow, skipped-key TTL, header-key rotation under loss).

---

## Low — outstanding

### TD-68 — Hex-encoded reset-token expiry duplicated as literal
`apps/server/src/routes/auth.rs:479,530` — extract to `const RESET_TOKEN_TTL: chrono::Duration`.

### TD-69 — HKDF zero-salt domain-separation risk
`apps/client/lib/src/services/crypto_service.dart:1770-1775`. Acceptable with a fresh ephemeral key per wrap; document the constraint so future reuse of `encryptForUser` doesn't silently weaken it.

### TD-70 — Chunked upload temp files survive server restarts
`apps/server/src/routes/media_chunked.rs:142-153, 542-568`. Cleanup loop sweeps only when running. **Fix:** On startup, walk `./uploads/.tmp/` and unlink files not referenced by a pending `upload_sessions` row.

### TD-71 — `tracing::error!("Database error: {:?}", err)` may echo column values
`apps/server/src/error.rs:223`. `sqlx::Error::Database` Debug formatting includes constraint-violation column values for some Postgres errors. **Fix:** Log structured fields (`code`, `constraint`, `severity`) instead of `{:?}`.

### TD-72 — `cleanup_expired_messages` 30 s cadence is aggressive
`apps/server/src/main.rs:53`. Most-tick wasted I/O when no expirations are due. **Fix:** Drop cadence to 5 min, OR maintain in-memory min-heap of next-expiry timestamps.

### TD-73 — `forgot_password` returns empty body on 200
`apps/server/src/routes/auth.rs:503`. Cosmetic — `Json(json!({}))` keeps the response shape consistent.

### TD-74 — `serde_json` parser-position leaks to client
`apps/server/src/ws/events/dispatch.rs:43`. Drop the `{e}` interpolation in WS error replies.

### TD-75 — Late `_voiceSignalController.broadcast()` subscribers miss events
`apps/client/lib/src/providers/websocket_provider.dart:40-41`. Currently mitigated by lifecycle ordering but fragile.

### TD-76 — `_expireTimer` rebuilds whole bubble subtree every second
`apps/client/lib/src/widgets/message_item.dart:235-256`. **Fix:** Wrap only the expiry-chip in a `ValueListenableBuilder<DateTime>` driven by the timer.

### TD-77 — `_messageKeys` map grows unbounded per ChatPanel lifetime
`apps/client/lib/src/widgets/chat_panel.dart:131, 244`. Long-lived heavy-traffic chats accumulate `GlobalKey`-anchored Elements. **Fix:** Prune entries on `findChildIndexCallback` cycles, or evict in `_onScroll`.

### TD-78 — `ListView.builder.itemBuilder` calls `ref.watch` inside builder
`apps/client/lib/src/widgets/chat_panel/chat_message_list.dart:208-212`. Stale per-row reads + over-broad subscription. **Fix:** Hoist `ref.watch` to `build()`; use `.select` for narrow fields.

### TD-79 — `chat_message_list` re-parses `DateTime` ~4N times per build
`apps/client/lib/src/widgets/chat_panel/chat_message_list.dart:140-180`. **Fix:** Pre-compute `DateTime parsedTimestamp` once on `ChatMessage`.

### TD-80 — `ConversationItem._applyMediaLabel` constructs RegExp in build
`apps/client/lib/src/widgets/conversation_item.dart:231`. Lift to top-level `final`.

### TD-81 — Channel chips built eagerly (no horizontal builder)
`apps/client/lib/src/widgets/channel_bar.dart:441-462`. 50+ channels = all chips rebuilt every channel-bar tick. **Fix:** `ListView.builder` with `scrollDirection: Axis.horizontal`.

### TD-82 — No fuzz / property tests anywhere
`proptest` / `quickcheck` / `fuzz_target` grep returns zero. Wire-format parsers (`signal/protocol.rs`, group envelope decode, WS frame parser) are the exact surface that would benefit. **Fix:** `core/rust-core/tests/wire_fuzz.rs` proptest on random `Vec<u8>` of 0..2 KiB; assert success-or-typed-error, never panic / OOB read.

### TD-83 — Playwright `test.fixme` without issue links
`tests/e2e/group_messaging_ui.spec.ts:351, 389, 442, 500, 597`. Five disabled core group flows. **Fix:** File tracking issues or delete.

### TD-84 — `_AuthNotifierListenable` never disposes its `ref.listen` subscription
`apps/client/lib/src/router/app_router.dart:77-81, 177`. Fine for app lifetime today but leaks if `routerProvider` is ever invalidated. **Fix:** Capture the subscription and cancel in `dispose()`.

### TD-85 — `splash_screen.dart` snackbar after navigation
`apps/client/lib/src/screens/splash_screen.dart:243-254`. PostFrameCallback fires `ScaffoldMessenger` against a context that just navigated away. **Fix:** Move warning to home screen or a global toast surface.

---

## Progress tracking — 2026-05-25 batch

- [x] TD-24 reset-token log leak — this commit
- [x] TD-25 reset_password tx — this commit
- [x] TD-26 byte-range streaming — this commit
- [x] TD-27 JWT device revocation (min-iat invalidator) — this commit
- [~] TD-28 ★ sign group-key envelopes — primitives + 3 unit tests shipped; rotation-path rollout pending schema/server work
- [x] TD-29 TOFU silent overwrite — canonical/pending split, `pendingPeerIdentityKey` getter, `acceptIdentityKeyChange` promotes
- [x] TD-30 ★ enforce recipient_device_contents includes peer — async DB lookup + `dm-peer-not-in-recipients` rejection code
- [x] TD-31 link_preview SSRF deny-list + port allowlist + async DNS — 12-CIDR deny list, port {80,443}, `tokio::net::lookup_host`, 9 unit tests
- [x] TD-32 IPv4-mapped IPv6 normalization — `to_ipv4_mapped()` unwrap before private-range check, 2 new unit tests
- [x] TD-33 group-member mutations in tx — per-(group,target) `pg_advisory_xact_lock`, `add_member_in_tx`/`remove_member_in_tx`/`ban_member_in_tx`
- [x] TD-34 HTTP status code remap (401→403, 400→404) — `NotMember` → 403; message/user/key not-found → 404; test fixtures updated
- [x] TD-35 typed voice/canvas event payloads — bounded sizes (8 KB voice, 16 KB canvas) at dispatch boundary
- [x] TD-36 WS rate-limit Ping/Binary counter (15-min fix) — `handle_other_frame` now decrements `bucket.tokens`
- [x] TD-37 shutdown coordination for cleanup + push tasks — `CancellationToken` + `JoinHandle` collection, two-stage drain
- [x] TD-38 reset_device tx — `revoke_device_in_tx` extracted, `clear_device_fingerprint` + revoke share one tx
- [x] TD-39 HTTP caching headers on avatars/media — weak ETag `(size, mtime)`, `If-None-Match` → 304 for avatars + media + thumbnails
- [x] TD-40 OTP concurrency test — N+1 concurrent reads, asserts N unique key_ids + 1 null
- [x] TD-41 WS rotation-storm integration test — N concurrent rotations of same version, asserts exactly 1 wins, 3 lose with 409, stored envelope is single-racer
- [x] TD-42 refresh-token theft cascade depth-N test — T0→T1→T2→T3 chain, replay T0 invalidates T3
- [ ] TD-43..TD-67 medium batch (eligible for a single follow-up PR)
- [ ] TD-68..TD-85 low batch (eligible for a single mechanical cleanup PR)

---

# 2026-05-29 voice-lounge focused audit (VL-1..VL-31)

Focused multi-agent audit of the voice-lounge feature after a string of crash/bug reports, run on `main @ 0c8fb258` (immediately after the canvas rewrite #1278). Scope: the ~9.2k LOC voice-lounge surface (screen, canvas providers, gesture state machine, stroke rendering, livekit provider, server voice/canvas routes + WS events). Five parallel reviewers: lifecycle/crash, gesture/render, state/sync-race, server-side, test-quality. ~31 de-duplicated findings; **1 critical, 6 high, 14 medium, 10 low**. The two crash claims (VL-1, VL-2) were verified by hand against the source.

Convergent theme across reviewers: **untrusted/peer canvas data reaches the client with no input hardening, and server geometry validation ships disabled (`LogOnly`) — so a single malformed frame crashes the whole client.** This is the most likely root cause of the reported crashes. The lifecycle crash class (ref-after-dispose) is largely already defended from prior fixes; the remaining lifecycle gaps are narrow.

## Critical

### VL-1 ★ — A single malformed `canvas_event` WS frame crashes the entire client
**File:** `apps/client/lib/src/providers/ws_message_handler.dart:15` (no try/catch around the dispatch switch) → `:675` `_handleCanvasEvent` → `canvas_provider.dart:931` `handleCanvasEvent` → `apps/client/lib/src/models/canvas_models.dart:177` `CanvasStroke.fromJson`
**Severity:** critical (verified)
**Source:** test-quality + state-sync + gesture reviewers (convergent)
**What:** `handleServerMessage` has no try/catch. `CanvasStroke.fromJson` does unguarded casts: `json['id'] as String`, `(json['width'] as num).toDouble()`, `(json['points'] as List)`. A `canvas_event` whose payload is missing a field / has `points: null` / `width` as a string throws `TypeError` synchronously, unwinding the whole WS message loop. Because server geometry validation defaults to `LogOnly` (see VL-16), malformed payloads genuinely reach clients. A sibling crash: `_parseColor` (`lounge_canvas_strokes.dart:445`) calls `int.parse(s, radix:16)` with no try/catch — a peer stroke with a non-hex color string throws inside `CustomPainter.paint()`, corrupting the frame for everyone.
**Fix:** (1) wrap each handler dispatch (or at minimum `_handleCanvasEvent`) in try/catch that logs + drops the frame; (2) make `CanvasStroke.fromJson` / `CanvasPoint.fromJson` / `CanvasImage.fromJson` defensive (validate types, drop bad frames); (3) wrap `_parseColor` to fall back to a default. **This is the recommended first fix.**
**Effort:** small

## High

### VL-2 ★ — Stroke coordinates committed unclamped → off-canvas persistence + legacy-coord rescale corruption
**File:** `apps/client/lib/src/screens/voice_lounge_screen.dart:1466` (`_onStrokeStart`/`_onStrokeMove` build `CanvasPoint` with no clamp); interacts with `_migrateLegacyCoord` in `canvas_provider.dart`
**Severity:** high (verified unclamped)
**Source:** gesture/render reviewer
**What:** The new stroke path builds points directly from the inverse-matrix canvas point with no `.clamp(0, kCanvasWidth)`, unlike the now-orphaned `lounge_drawing_canvas.dart:42` which clamped. Panning past the 0..100k surface (pan is also unclamped — VL-21) yields negative / >100k coords that are persisted and broadcast. On reload, `_migrateLegacyCoord` treats any coord ≤ 1.0 as legacy and multiplies by 4096 — so a stroke drawn near the origin edge gets scattered.
**Fix:** clamp x/y to `[0, kCanvasWidth/Height]` in `_onStrokeStart`/`_onStrokeMove` (restore the old clamp).
**Effort:** small

### VL-3 — Stale-session sweep evicts live-but-idle voice participants (no `updated_at` heartbeat)
**File:** `apps/server/src/db/channels.rs:283` (cleanup `WHERE vs.updated_at < now() - interval`); `apps/server/src/ws/handler.rs:39` (WS heartbeat never touches the row)
**Severity:** high
**Source:** server reviewer
**What:** The 60s `cleanup_stale_voice_sessions` (called with 120s max-age) deletes a participant whose `voice_sessions.updated_at` is older than 120s and broadcasts `voice_session_left`. Nothing in the WS receive path bumps `updated_at` except `join`/`update_voice_state` — so a user sitting in a call for >120s without toggling mute/PTT gets ghosted out while their socket is alive, and subsequent canvas writes are then rejected ("Join the voice channel before signaling").
**Fix:** add a lightweight periodic `voice_heartbeat` that does `UPDATE voice_sessions SET updated_at = now()`, or refresh on the existing WS heartbeat tick. Or raise the threshold well above the idle window and document it.
**Effort:** medium

### VL-4 — Incoming `stroke` / `image_add` appended with no dedup → duplicates accumulate & diverge
**File:** `apps/client/lib/src/providers/canvas_provider.dart:1003` (stroke), `:1016` (image)
**Severity:** high
**Source:** state-sync reviewer
**What:** Handlers blind-append without checking whether the id already exists. On reconnect snapshot-replay overlapping live events, or `importSnapshot` re-broadcasting strokes a peer already has, the same stroke lands twice; boards diverge across clients.
**Fix:** dedup on receive — replace-in-place if id exists, else add. Same for `image_add`.
**Effort:** small

### VL-5 — Unbounded client stroke/image growth (no cap mirroring the server)
**File:** `apps/client/lib/src/providers/canvas_provider.dart:487, 1008, 1018`
**Severity:** high
**Source:** state-sync reviewer
**What:** Every committed stroke does a full `List.from(...)..add(...)` and grows `state.strokes` forever; freehand point lists are never decimated; eraser strokes accumulate rather than removing covered strokes. The server caps at 2000 strokes but the client has no cap → long collaborative session OOMs / paint p99 collapses.
**Fix:** cap `state.strokes` to the server limit and reconcile on overflow; decimate freehand points on commit.
**Effort:** medium

### VL-6 — `clear` racing with in-flight strokes resurrects cleared content (no board-generation fence)
**File:** `apps/client/lib/src/providers/canvas_provider.dart:1010` (clear), `:999/1003` (stroke apply)
**Severity:** high
**Source:** state-sync reviewer
**What:** Peer A clears; peer B commits a stroke (or a buffered `stroke_partial` arrives) just after applying the clear → content reappears on everyone. Last-write-wins with no fence means clear is not reliably terminal.
**Fix:** stamp a monotonic board-generation counter on outbound strokes; drop inbound strokes predating the latest local `clear`; cancel any active local stroke when a remote `clear` is applied.
**Effort:** medium

### VL-7 — Lifting one finger during a 3-pointer pinch jumps the canvas (stale pinch baseline + wrong pointer pair)
**File:** `apps/client/lib/src/widgets/voice_lounge/lounge_canvas_gestures.dart:176, 387`
**Severity:** high
**Source:** gesture/render reviewer
**What:** With 3 fingers down (phase stays `pinching`, 3rd tracked in `_pointerOrder`), lifting one leaves `pointerCount == 2` — no transition fires, so the pinch baseline (`_pinchStartSpread`/midpoint, seeded from the original pair) is never re-seeded, but `_applyPinch` now reads a different pointer pair → discontinuous scale snap.
**Fix:** re-seed the pinch baseline whenever the active pinch pair changes (any pointer up/down while pinching with ≥2 remaining).
**Effort:** medium

### VL-8 — The two highest-crash-risk units have zero real test coverage
**File (tested via inline re-implementation, not the real method):** `canvas_provider.dart:931` `handleCanvasEvent`; **untested entirely:** `livekit_voice_provider.dart:296/669` `joinChannel`/`leaveChannel`/`_teardownCurrent`; `voice_lounge_screen.dart` (1884 lines, no direct test)
**Severity:** high
**Source:** test-quality reviewer
**What:** `canvas_provider_test.dart` re-implements the `handleCanvasEvent` switch inline ("simulate what handleCanvasEvent does") — `grep '\.handleCanvasEvent('` over `test/` returns zero hits — so the real unguarded entry point (VL-1) is never exercised. `livekit_voice_provider_test.dart` only tests immutable state objects; the documented rejoin/dispose-during-connect race in `joinChannel` is never executed. The 30-file test suite gives false confidence: the gesture state machine and detach-during-attach race are genuinely well covered, but the crash-prone WS handler, connection lifecycle, and the screen itself are not.
**Fix:** add real `handleCanvasEvent` malformed-frame tests (drives VL-1); add a Room seam/fake to exercise double-`joinChannel` re-entrancy + channel-switch teardown ordering; add a screen pump-then-dispose-during-join test.
**Effort:** large

## Medium

### VL-9 — `setCaptureEnabled` / `setDeafened` mutate `state` with no `_disposed` guard
**File:** `apps/client/lib/src/providers/livekit_voice/livekit_voice_av_controls.dart:24, 50`
**Severity:** medium — **What:** every sibling method (`toggleVideo`, `switchCamera`, `setScreenShareEnabled`) guards `if (_disposed)`, these two don't. A queued CallKit/notification `VoiceMuteAction` firing after dispose (cancellation is synchronous but can't drain an already-queued event) assigns `state` on a disposed Notifier → `StateError`. **Fix:** add `if (_disposed) return;` at entry and after the await. **Effort:** small

### VL-10 — `floating_dock._handleLeave` has no try/finally → Leave button can wedge permanently
**File:** `apps/client/lib/src/screens/voice_lounge/floating_dock.dart:82` — **What:** if `channels.leaveVoiceChannel` throws, `_isLeaving` is never reset and the button (`onPressed: _isLeaving ? null : ...`) is permanently disabled — user stuck in the lounge. Also redundantly calls `leaveVoiceChannel` which `livekit.leaveChannel()` already does (`provider.dart:690`). **Fix:** wrap in try/finally resetting `_isLeaving` with a `mounted` guard; drop the redundant call. **Effort:** small

### VL-11 — `RoomDisconnectedEvent` doesn't stop the RTC/audio poll timers
**File:** `apps/client/lib/src/providers/livekit_voice/livekit_voice_provider.dart:872` — **What:** on an unexpected SFU disconnect, only `_cleanupRoom` (via explicit leave) stops the 2s stats/audio timers; the disconnect handler doesn't, so timers keep reflecting into a dead room until the next join/leave (throw is swallowed → CPU leak, not a hard crash). **Fix:** call `_stopRtcStatsPolling()` + `_stopAudioLevelPolling()` in the disconnect handler. **Effort:** small

### VL-12 — Canvas authority never cleared on `detach()` → stale write-lock locks out next session of the same channel
**File:** `apps/client/lib/src/providers/canvas_provider.dart:179`; `canvas_authority_provider.dart:29` — **What:** `detach()` resets canvas state but never calls the (keepAlive, channel-keyed) authority notifier's `clear()`. On rejoin of the same channel, the stale authority device id persists; if that device is gone, `_canIWrite()` is false for everyone → nobody can draw until a manual re-claim. **Fix:** call authority `clear()` for the channel in `detach()`. **Effort:** small

### VL-13 — Server stale-session sweep doesn't clear canvas authority (only the disconnect path does)
**File:** `apps/server/src/main.rs:296`; cf. `apps/server/src/ws/events/voice.rs:158` — **What:** the WS-disconnect path calls `canvas_authority.clear_on_leave`, but the periodic stale sweep (the exact crashed-client/backgrounded case) broadcasts the leave without clearing authority → dead device holds the canvas, no handoff. **Fix:** clear authority for every evicted session in the sweep. **Effort:** small

### VL-14 — LiveKit token grant is uniformly full-publish, 1h expiry, no post-kick eviction
**File:** `apps/server/src/routes/voice.rs:149` — **What:** every member (including listeners) gets `can_publish: true`; a member removed seconds after minting retains SFU publish for up to an hour (LiveKit validates the JWT independent of the membership table). **Fix:** role-scope grants, shorten exp to ~5-10 min with client refresh, evict via LiveKit server API on removal. **Effort:** medium

### VL-15 — `clear` event ignores `scope:"mine"` and always wipes the whole shared board
**File:** `apps/server/src/ws/events/canvas.rs:133`; validator accepts `"mine"` at `canvas_validation.rs:285` — **What:** `persist_canvas_state` routes every `clear` to `clear_all` regardless of scope, so any member emitting `clear` (even `scope:"mine"`) destroys everyone's work — a griefing/authz gap and a silently-violated wire contract. **Fix:** branch on scope (delete only author's objects for `"mine"`), or remove `"mine"` from the validator. **Effort:** medium

### VL-16 — Geometry validation defaults to `LogOnly` → non-blocking in production (enables VL-1)
**File:** `apps/server/src/ws/events/canvas.rs:38, 75` — **What:** `CANVAS_VALIDATION_MODE` defaults to `LogOnly`; in that mode `apply_validation` logs but returns `true`, so the entire PR #1269 geometry suite is non-blocking until ops flips the env. Malformed/huge coordinates and cross-conversation `image_add` URLs still persist + fan out. **Fix:** flip default to `Enforce` if the documented ~2-week soak has elapsed; additionally validate `image_add` URLs reference media owned by this conversation. **Effort:** small

### VL-17 — Live eraser preview is a no-op (`BlendMode.dstOut` can't cross the RepaintBoundary)
**File:** `apps/client/lib/src/widgets/voice_lounge/lounge_canvas_strokes.dart:251` — **What:** the active stroke lives on L2 (separate layer above committed L1); `dstOut` inside L2's own `saveLayer` only clears L2's empty raster — committed strokes on L1 aren't touched until pointer-up commit. So dragging the eraser shows nothing erasing, contradicting the live-preview contract. **Fix:** preview the eraser against the committed layer, or render it as a translucent stroke. **Effort:** large

### VL-18 — Committed-strokes `shouldRepaint` only diffs the last stroke → missed repaints
**File:** `apps/client/lib/src/widgets/voice_lounge/lounge_canvas_strokes.dart:224` — **What:** compares only `strokes.length` and the trailing element's id/point-count; an undo/remove returning to the prior length, a remote in-place edit of a middle stroke, or a color/width change to the last stroke renders stale. Contradicts the spec's `strokesRevision`-drives-L1 contract (the painter doesn't use the revision counter at all). **Fix:** compare an incrementing `strokesRevision` int. **Effort:** small

### VL-19 — Server excludes by user-id, not device-id → a user's 2nd device never sees the 1st's strokes
**File:** `apps/server/src/ws/events/canvas.rs:339` (`broadcast_json(..., Some(sender_id))`) — **What:** canvas strokes are relayed excluding the sender's user UUID, so all of that user's connections are excluded; a read-only second device never receives the authority device's strokes — contradicts the multi-device read-only-viewer intent. Contrast `canvas_authority_changed` which correctly uses `None`. **Fix:** exclude by device/connection id, or use `None` + client-side own-stroke dedup (which needs VL-4). **Effort:** medium

### VL-20 — Local state mutates before the authority gate → ghost strokes on non-authority devices
**File:** `apps/client/lib/src/providers/canvas_provider.dart:487` (local append) vs `:1088` (`_canIWrite` checked only inside `_sendCanvasEvent`) — **What:** `endStroke` appends locally before the send-time authority gate drops the broadcast; a non-authority device accumulates strokes nobody else has → permanent local divergence until clear. **Fix:** check `_canIWrite()` before mutating local state. **Effort:** medium

### VL-21 — Pan transform never clamped → infinite drift, content lost off-screen
**File:** `apps/client/lib/src/widgets/voice_lounge/lounge_canvas_gestures.dart:360` — **What:** `_applyPanDelta` adds raw deltas with no clamp against the 100k surface; with `minScale=0.2` the surface can be panned entirely out of view, recoverable only via reset-view. Also the upstream cause of VL-2's off-canvas coordinates. **Fix:** clamp post-pan translation so a margin of content/surface stays in view. **Effort:** medium

### VL-22 — Double-tap with a second finger during a pan desyncs pointer tracking → combined zoom+pan jump
**File:** `apps/client/lib/src/widgets/voice_lounge/lounge_canvas_gestures.dart:239` — **What:** the double-tap branch runs before checking that exactly one pointer is down; a second finger tapped during an in-progress pan passes the double-tap test, is removed from tracking and `return`s without telling the state machine, leaving `_phase == panning` with two pointers down → zoom fires mid-pan. **Fix:** only treat a pointerDown as double-tap when `_pointers.length == 1` and `_phase == idle`. **Effort:** small

## Low (batch — eligible for a single cleanup PR)

- **VL-23** — `importSnapshot` / `clearMyDrawings` fire a burst of per-stroke WS events; a large import hits the server stroke cap mid-stream and silently truncates peers' boards with no error surfaced. (`canvas_provider.dart:544`) — server atomic "replace board" event or chunk+ack.
- **VL-24** — Nonce LiveKit identity (PR #1235, otherwise sound) has no per-user participant cap; scripted token requests mint unlimited publishing participants into one room. (`voice.rs:92`) — set room `maxParticipants` / evict prior same-user participants.
- **VL-25** — `voiceLoungeFullscreenProvider` / `voiceLoungeViewModeProvider` are global `StateProvider`s not reset on lounge *exit* → next join can start in stale fullscreen/canvas mode. (`voice_lounge_fullscreen_provider.dart:7`) — reset on confirmed leave.
- **VL-26** — Partial-stroke placeholder id keyed on `fromUserId` only collides across a user's concurrent devices / re-creates after the final stroke. (`canvas_provider.dart:975`) — key on `(userId, deviceId)` or a wire-carried partial id.
- **VL-27** — Server canvas validation runs *before* membership/channel checks → a non-member can probe validation error codes for any channel_id and burn validation CPU. (`canvas.rs:277`) — reorder authz first.
- **VL-28** — Voice signal relay issues 5 sequential DB round-trips per frame (ICE bursts × group size). (`voice.rs:49-132`) — collapse into one JOINed query; cache static channel/conversation kind.
- **VL-29** — `update_image` (image_move) rewrites the full client object (≤16 KB) with a whole-array JSONB rewrite per move, no field projection or per-image cap. (`db/canvas.rs:212`) — server-side projection to position/size only.
- **VL-30** — `get_canvas` returns the entire board (up to ~32 MB) unpaginated on every lounge join. (`routes/canvas.rs:56`) — paginate/chunk or gzip; lower per-stroke point cap.
- **VL-31** — Single-tap with a shape tool commits an invisible 1-point "shape" that is persisted/broadcast but never renders (`_paintShape` needs ≥2 points). (`lounge_canvas_gestures.dart:164`) — drop shape strokes with <2 distinct points in `endStroke`.

## Recommended fix order
1. **VL-1** (input hardening — try/catch + defensive `fromJson` + `_parseColor`) — small, kills the likely crash root cause.
2. **VL-16** (flip validation to Enforce + image-URL ownership) — small, server-side defense-in-depth for VL-1.
3. **VL-2 + VL-21** (clamp strokes + pan) — small, fixes coordinate corruption.
4. **VL-3 + VL-13** (voice heartbeat + authority clear on sweep) — fixes phantom-eviction + stuck canvas.
5. **VL-4 + VL-6 + VL-12** (dedup + clear-generation fence + authority-clear-on-detach) — the divergence trio.
6. **VL-8** (real tests for the WS handler + connection lifecycle) — locks in the above.

Per-finding evidence (file:line + code quotes) captured in this session's audit run.

## Status — 2026-05-29 fix batch (critical + all high)

Shipped on `fix/voice-lounge-crash-batch`:

- [x] **VL-1** — `handleCanvasEvent` wrapped in try/catch (drops + logs malformed peer frames instead of crashing the WS loop); `_parseColor` uses `tryParse` + fallback. Tests drive the **real** `handleCanvasEvent` via a `ProviderContainer`.
- [x] **VL-2** — stroke points clamped to the surface in `_onStrokeStart`/`_onStrokeMove` (`_clampedCanvasPoint`).
- [x] **VL-3** — WS heartbeat calls `touch_user_voice_sessions` every 30s so the 120s sweep no longer evicts connected-but-idle members. DB-level regression test added.
- [x] **VL-4** — inbound `stroke` / `image_add` dedupe by id (replace-in-place).
- [x] **VL-5** — client stroke/image lists capped to the server limit (2000), oldest-first trim.
- [~] **VL-6** — remote `clear` now aborts an in-flight local stroke (`_abortActiveStroke`), closing the common same-device resurrection. **Residual:** the cross-peer case (a stroke committed before a peer saw the clear, arriving after) still needs a server-assigned board-generation/sequence to fence fully — kept open.
- [x] **VL-7** — **FALSE POSITIVE.** The audit assumed `_seedPinch` fires only on phase *change*; in fact `_applyTransition` re-seeds on every transition that lands in `pinching`, so the 3-finger lift already re-seeds and does not jump. Added a widget regression test + a guard-rail comment so a future refactor can't reintroduce it. No code change to the gesture math.
- [~] **VL-8** — the `handleCanvasEvent` half is now covered by `canvas_provider_hardening_test.dart` (drives the real method, the crash-linked gap). The LiveKit `joinChannel`/`leaveChannel`/teardown-race half remains open: it needs a `Room`-injection seam in `livekit_voice_provider.dart` first (a production refactor out of scope for this batch). **Follow-up.**

## Status — 2026-05-29 follow-up batch (medium/low, verified-then-fixed)

Each item below was re-verified against the actual code before any change (VL-7
proved the audit isn't infallible). Shipped on `fix/voice-lounge-crash-batch`:

- [x] **VL-9** — `_disposed` guard added to `setCaptureEnabled` / `setDeafened` (the only AV methods missing it); prevents a queued CallKit/notification action assigning `state` on a disposed Notifier.
- [x] **VL-10** — `_handleLeave` resets `_isLeaving` on a thrown teardown (no permanent button wedge) and stops double-calling `leaveVoiceChannel` (delegated to `leaveChannel`). Dock + lifecycle tests updated to the corrected single-call contract.
- [x] **VL-11** — `RoomDisconnectedEvent` stops the RTC-stats + audio-level poll timers (they restart on next join).
- [x] **VL-12** — `detach()` clears per-channel canvas authority (regression test added).
- [x] **VL-13** — the stale-voice-session sweep clears canvas authority for evicted sessions, mirroring the disconnect path.
- [x] **VL-18** — committed-strokes `shouldRepaint` now compares list identity (repaints on any mutation, not just a last-element change) — cheap because the list is reference-stable from watched state.
- [x] **VL-20** — the canvas-authority gate is applied before the LOCAL mutation in `endStroke`/`addTextLabel`/`addImage`, not only in the broadcast — a read-only device no longer accumulates ghost content.
- [x] **VL-22** — double-tap is gated to a sole pointer on an idle canvas, so a 2nd finger during a pan enters pinching instead of mis-firing a zoom (regression test added).
- [x] **VL-27** — channel-lookup + membership check moved before canvas geometry validation (no validation-oracle / wasted work for non-members).
- [x] **VL-31** — a shape tapped without dragging (single point) is dropped in `endStroke` instead of persisting an invisible zero-size shape (regression test added).

### Deliberately deferred (verified valid but NOT fixed this batch, with reason)

- **VL-14** (LiveKit token roles / short expiry / post-kick eviction) — needs a product decision (is there a listener-only role?) and the LiveKit server API for eviction. Product/infra call, not a code-correctness fix.
- **VL-15** (`clear scope:"mine"`) — per-user clear requires per-stroke author tracking (a schema/data-model change); clear-all-by-any-member is documented intent. The only quick change (drop `"mine"` from the validator) is a marginal wire-contract tweak with its own risk. Left for a dedicated design pass.
- **VL-16** (flip validation to `Enforce`) — an **ops** decision gated on the documented soak window, not a code change; flipping enforcement is a behavior change that needs a deliberate rollout. The image-URL-ownership half needs a media-authz analysis first.
- **VL-17** (live eraser preview is a no-op) — large architectural: `BlendMode.dstOut` fundamentally can't composite across the L1/L2 `RepaintBoundary` split. Needs a rethink of the layer model.
- **VL-19** (per-user vs per-device broadcast exclude) — switching to `None` + relying on the new VL-4 dedup is plausible now, but it changes broadcast semantics for ALL canvas kinds and interacts with `stroke_partial` self-echo; deferred pending a real multi-device test harness.
- **VL-21** (pan never clamped) — conflicts with the documented Miro-style infinite-canvas intent ([[feedback_canvas_navigation]]); the reset-view button is the intended recovery. A clamp is a UX decision, not a clear bug.
- **VL-23** (import truncation at the server cap) — needs an atomic "replace board" event or chunked acks (protocol work).
- **VL-24** (no per-user LiveKit participant cap) — LiveKit room config / product.
- **VL-25** — **NOT A BUG.** Fullscreen IS already reset on `dispose()` (`voice_lounge_screen.dart`). View-mode persistence across remounts is intentional (its own doc explains resetting it re-breaks the fullscreen-toggle remount bug).
- **VL-26** (partial-stroke placeholder keyed by user only) — needs a `from_device_id` in the server broadcast payload; largely mitigated already by VL-20 single-writer gating.
- **VL-28** (voice-signal relay does 5 sequential DB queries) — perf optimization, rate-limited (3 msg/s), non-crash. Query-collapse refactor for a later perf pass.
- **VL-29** (`update_image` rewrites the full client object) — perf/hardening, bounded by the 16 KB frame cap + rate limit, non-crash.
- **VL-30** (GET canvas unpaginated) — large/design (pagination or streaming of the stroke/image arrays).

Still open after both batches: the VL-6 cross-peer residual, the VL-8 LiveKit-seam test, and VL-14/15/16/17/19/21/23/24/26/28/29/30 as scoped above.
