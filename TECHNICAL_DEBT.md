# Technical Debt — Echo Messenger

Captured from the 2026-05-20 multi-agent audit of the 26 PRs (#980–#1005) shipped on the same day. The mechanical / low-risk items were applied in the audit follow-up PR; this file tracks the remaining work that needed design judgment, larger refactors, or test infrastructure beyond a single follow-up commit.

Audit baseline commit range: `628e623ebd6108b230f313ccebdcb922e6f09e3d^..HEAD` (40 files, +1838/-756 lines). 6 reviewers ran in parallel (code-quality, security, performance, frontend, backend, test-coverage). ~66 findings total; 3 critical, 11 high, 28 medium, 24 low. Convergent risk across all reviewers: the rotation-storm on `member_added` and the lack of single-flight in self-heal — partially addressed in the follow-up PR with a per-conversation in-flight set, but the parallel identity-key fetch optimization remains.

Last updated: 2026-05-20.

## Summary
- Critical / High remaining: 0  (TD-1..TD-4 shipped in PR #1007)
- Medium remaining: 1  (TD-14 — conversation Map index; deferred)
- Low remaining: 2  (TD-20 partial schema migration, TD-23 harder test surfaces)

The medium/low cleanup batch landed across server + client + tests (TD-5..TD-13, TD-15..TD-19, TD-21, TD-22, partial TD-23).

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
