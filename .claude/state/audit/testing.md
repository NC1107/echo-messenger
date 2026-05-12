# Echo Messenger — Testing Coverage & Quality Audit

Single-pass audit of test gaps, weak assertions, and flaky-prone patterns.
Recent commits (be8bcee, 115478a, a36a01d, 9a06e21, 1b53277, 0ca58a2,
fb10596, c20b832, c76ce00) are the primary lens. Issue #782 (broken
maintained e2e suite) and #783 (prior tech-debt residue) are NOT restated.

---

### Finding 1: server-side mention persistence has zero integration coverage
- **File**: MISSING: `apps/server/tests/api_mentions.rs` (or extension to `api_messages_extra.rs`)
- **Severity**: high
- **Description**: Commit 1b53277 added a brand-new feature path (`db/mentions.rs::extract_and_persist`, mentions table, `mention_count` LATERAL CTE in conversations list, ws_message_service hook on group sends) — 317 net additions. The only tests are pure-string-matching unit tests (`extract_at_usernames`, `is_standalone_keyword`) inside `db/mentions.rs`. Nothing exercises the actual DB path: row insertion, dedup against the sender, `@everyone`/`@here` member fan-out, the new migration `20260509000000_mentions.sql`, or the conversations endpoint surfacing `mention_count`. A regression here would silently zero-out mention badges for every user. CLAUDE.md feature rule says "tests AFTER" — they were not added.
- **Fix**: Add integration tests against the real spawn_server: (a) `@alice` in a 3-member group inserts exactly one row for alice, none for sender; (b) `@everyone` inserts N-1 rows; (c) GET `/api/messages/conversations` returns `mention_count > 0` after a mention and `0` after `mark_read`; (d) a self-mention does not bump the sender's own count.
- **Effort**: medium

### Finding 2: WS empty/whitespace-content fix has no WS regression test
- **File**: MISSING: WS test in `apps/server/tests/ws_messaging.rs` paired with `apps/server/src/ws/message_service.rs:66`
- **Severity**: high
- **Description**: Commit 0ca58a2 added whitespace rejection to BOTH the REST edit path (`routes/messages.rs:445`) and the WS send path (`ws/message_service.rs:66`). The REST edit path has `edit_message_empty_content_returns_400` (api_messages_extra.rs:152) but only sends `""`, not `"   "` / `"\t\n"`, so the actual bug (whitespace bypassing the old `is_empty()` check) is untested. The WS send path has no coverage at all — the comment says "the WS path didn't [validate], which let clients persist a whitespace-only message" but there is no `ws_messaging.rs` test that sends `{type:"send_message", content:"   "}` and asserts an error. This is exactly the bug the fix targeted.
- **Code** (apps/server/src/ws/message_service.rs:64-66):
  ```
  /// trim because base64 of a real ciphertext doesn't whitespace-out.
  if content.trim().is_empty() {
  ```
- **Fix**: Add `#[tokio::test] ws_send_whitespace_only_content_rejected()` — connect alice, send `content: "   \t\n"`, assert error event. Also extend `edit_message_empty_content_returns_400` with `"   "` as a second case.
- **Effort**: small

### Finding 3: reaction-aggregation regression fixes (fb10596, c20b832) untested
- **File**: MISSING: assertion in `apps/server/tests/api_messages.rs` or `api_reactions.rs`
- **Severity**: high
- **Description**: Two consecutive bug fixes (fb10596 "aggregate reactions into message-list and thread-replies queries", c20b832 "keep MessageWithSender backed by reactions column on all queries") modified `db/messages.rs` to add LATERAL aggregates and `'[]'::json AS reactions` placeholders so MessageWithSender is uniformly shaped. These both shipped with **no test changes**. `apps/server/tests/api_reactions.rs` only tests POST/DELETE on /reactions (lines 117–276) — no test calls GET /api/messages/conversations/{id} after adding a reaction and asserts the response includes a populated `reactions` array. Same for /thread-replies. A regression would break reaction render on history scroll (the bug being fixed) and CI would stay green.
- **Fix**: Add `react_then_list_returns_aggregated_reactions()` — alice sends msg, bob reacts, alice GETs list, assert `body[0].reactions[0].emoji == "👍"`. Same shape for thread-replies endpoint.
- **Effort**: small

### Finding 4: thread-replies `?before=` pagination fix untested
- **File**: MISSING: regression test in `apps/server/tests/api_messages_reply_scope.rs`
- **Severity**: medium
- **Description**: Commit c76ce00 ("thread-replies endpoint honors ?before= for pagination") changed `db/messages.rs` and `routes/messages.rs` (+17 lines). No test was added. Grepping `apps/server/tests/` for `?before=` against thread-replies returns zero hits. The existing reply-scope tests only verify cross-conversation isolation, not pagination. A future refactor could silently regress `?before=` handling.
- **Fix**: Post 3 thread replies, GET `/messages/{id}/thread-replies?before=<middle_id>`, assert only the older reply is returned and the newer two are excluded.
- **Effort**: small

### Finding 5: WebSocketState reconnect-attempts test asserts a stale constant
- **File**: `apps/client/test/providers/websocket_provider_test.dart:234-238`
- **Severity**: medium
- **Description**: Test claims to verify the circuit-breaker limit but hard-codes the value rather than reading it from source. Since be8bcee migrated the provider to @riverpod codegen, the source actually sets `_maxReconnectAttempts = 1000` (websocket_provider.dart:35) — the test still asserts `10`. The test passes trivially (it's just `expect(10, 10)`), so it provides zero protection. Worse, the entire backoff group recomputes the formula in test code (`int backoffMs(int attempt) { return math.min(1000 * math.pow(2, attempt).toInt(), 60000); }`) instead of invoking the real `_scheduleReconnect`, so a real change to the production formula would not be caught.
- **Code** (websocket_provider_test.dart:236-238):
  ```
  // Verify the circuit breaker limit -- this is the value in
  // WebSocketNotifier._maxReconnectAttempts.
  const maxReconnectAttempts = 10;
  ```
- **Fix**: Either expose `_maxReconnectAttempts` as a `@visibleForTesting` constant and assert against the real value, or delete the test — asserting a duplicated literal protects nothing. For backoff, fake-async the timer and observe actual scheduled durations, not a re-implementation.
- **Effort**: small

### Finding 6: extracted message widgets ship without direct unit tests
- **File**: MISSING: tests for `apps/client/lib/src/widgets/message/{sender_name_label,reply_count_badge,message_indicators,message_status_icon,hover_action_button,system_event_pill,retry_row,link_preview_card}.dart`
- **Severity**: medium
- **Description**: Commits a36a01d ("extract sender_name_label + reply_count_badge from message_item") and 9a06e21 ("extract small message_item renderers to message/ files") split message_item.dart into 15 widget files. Direct test grep:
  - `sender_name_label.dart` — 0 test imports
  - `reply_count_badge.dart` — 0 test imports
  - `message_indicators.dart`, `message_status_icon.dart`, `hover_action_button.dart`, `system_event_pill.dart`, `retry_row.dart`, `link_preview_card.dart` — 0 test imports
  Coverage relies entirely on transitive testing through `message_item_test.dart`. A bug like wrong density-based font size, wrong "1 reply" vs "N replies" pluralisation, or wrong `isMine` alignment in `reply_count_badge.dart` would only fail if the parent test happened to render that branch with the right inputs. Refactor commits without tests is the exact pattern CLAUDE.md guards against.
- **Fix**: Add at minimum `sender_name_label_test.dart` (verify font size per UIDensity, name + timestamp row in compact, name-only in bubbles, color matches `senderLabelColor`) and `reply_count_badge_test.dart` (singular vs plural label, alignment by isMine, semantics label `"View N replies"`, onTap fires).
- **Effort**: medium

### Finding 7: mentionCount field on Conversation has no client-side test
- **File**: MISSING: assertion in `apps/client/test/providers/conversations_provider_test.dart` or `models/conversation_test.dart`
- **Severity**: medium
- **Description**: Commit 1b53277 added `mentionCount` to `apps/client/lib/src/models/conversation.dart` (lines 17-100), parsed from `json['mention_count']`, threaded through copyWith and equality. There is no test that constructs a Conversation from `{"mention_count": 3}`, asserts `c.mentionCount == 3`, or checks that copyWith preserves mentionCount when not overridden. Same risk as Finding 1 on the server side: a JSON-key typo regression (e.g. someone renames to `mentionCount` in JSON) silently zeros out badges.
- **Fix**: Two-line test: `final c = Conversation.fromJson({...'mention_count': 5}); expect(c.mentionCount, 5);` plus a copyWith preservation test.
- **Effort**: small

### Finding 8: db_mentions tests are pure-string regex without DB pool exercise
- **File**: `apps/server/src/db/mentions.rs:190-234`
- **Severity**: medium
- **Description**: The `#[cfg(test)] mod tests` block only verifies `extract_at_usernames` (a pure regex helper). The actually-public function `extract_and_persist` (the only thing routes call) — which builds the targets list, hits `conversation_members`, dedups, drops the sender, and inserts via `UNNEST` with `ON CONFLICT DO NOTHING` — has zero coverage. CLAUDE.md saved feedback says mocked-DB tests caused a prod migration miss; this module has gone the opposite extreme and tests nothing that touches the DB at all. The `is_removed = false` filter, the `LOWER(u.username) = ANY($2)` cast, and the dedup math could all silently break.
- **Code** (apps/server/src/db/mentions.rs:194-196):
  ```
  fn extracts_simple_username() {
      assert_eq!(extract_at_usernames("hi @alice"), vec!["alice"]);
  ```
- **Fix**: Add `#[sqlx::test]` (or integration-style spawn_server) tests for `extract_and_persist`: 3-user group, send `@alice @alice @bob` → exactly 2 rows; send by alice with `@alice` → 0 rows (sender filter); kick alice (is_removed=true), send `@alice` → 0 rows.
- **Effort**: medium

### Finding 9: ws_messaging.rs uses lossy 150ms drain_pending instead of explicit waits
- **File**: `apps/server/tests/common/mod.rs:259-264`, used 30+ times in `ws_messaging.rs`
- **Severity**: medium
- **Description**: `drain_pending` reads frames with a 150ms per-frame timeout and stops when none arrive. Comment in source (lines 255-258) explicitly admits "the lossy 'best effort' model that the audit flagged as flaky, but kept here as an escape hatch." Despite that, every new test in `ws_messaging.rs` (including the recent #451 broadcast-mention tests at line 338-340) opens with `drain_pending(&mut alice_ws); drain_pending(&mut bob_ws);` — the supposed-escape-hatch is the default. On a busy CI runner where the presence_list snapshot lands >150ms after connect, the next assertion sees `presence_list` instead of `message_sent` and the test fails. `read_text_skipping_presence` papers over this for one frame type but not for all.
- **Fix**: Replace bulk `drain_pending` calls in new tests with `wait_for_event(ws, &["presence_list"])` (already used in api_messages_reply_scope.rs:31). For tests that genuinely don't know what's coming, document the flake in a `// FLAKY:` marker so it's findable by `grep`.
- **Effort**: medium

### Finding 10: encrypted-group plaintext-fallback has no Playwright/E2E coverage
- **File**: MISSING: spec in `tests/e2e/`
- **Severity**: medium
- **Description**: The #344 fix made `sendGroupMessage` hard-fail on encryption errors instead of silently falling back to plaintext (the previous behaviour was a confidentiality leak). Coverage exists at the unit level: client `websocket_send_test.dart:441` and server `ws_messaging.rs:1278 encrypted_group_rejects_plaintext_send`. There is no full-stack E2E: launch two browsers, create encrypted group, simulate one client lacking the group key, type a message, assert the message never appears in the room and a failure indicator is shown. Audit prompt #7 calls this out specifically. `tests/e2e/group_messaging_ui.spec.ts` only handles plaintext groups (the "plaintext" matches in that file are helper-comment hits, not test logic).
- **Fix**: Add `tests/e2e/encrypted_group_plaintext_block.spec.ts` driving two CanvasKit browsers; assert that an encryption-failed send produces a failed-message UI marker (the existing e2e harness has the user/contact/group helpers).
- **Effort**: large

### Finding 11: `ws_presence_snapshot.rs` uses `tokio::time::sleep(100ms)` as a synchronization primitive
- **File**: `apps/server/tests/ws_presence_snapshot.rs:70`
- **Severity**: medium
- **Description**: Test sleeps 100ms hoping the hub registers alice & bob before charlie connects. On a slow CI runner this races, on a fast runner it adds 100ms of dead time — the worst of both worlds. Audit prompt #4 ("tests that depend on production state … without seeding") and #6 ("flaky-prone patterns: sleeps instead of waits"). The `read_text_skipping_presence` helper exists; the right primitive is "spin until alice sees bob's online event, THEN connect charlie".
- **Code** (ws_presence_snapshot.rs:69-70):
  ```
  // Give the server a moment to register alice and bob in the hub.
  tokio::time::sleep(Duration::from_millis(100)).await;
  ```
- **Fix**: Replace the sleep with a deterministic wait: read frames from alice until she sees `online` for bob (signal that the hub has both), then connect charlie. Bounded timeout (e.g. 3s) protects against true hangs.
- **Effort**: small

### Finding 12: chat_provider codegen migration (115478a) added no notifier-API test
- **File**: `apps/client/test/providers/chat_notifier_test.dart` (only mutator coverage), gap in send/load coverage
- **Severity**: low
- **Description**: 115478a migrated `chat_provider` to @riverpod codegen and the diff shows existing tests adjusted only their `_createNotifier()` boilerplate (`+13 -10` per test file). The *actual* network-touching API surface — `loadMessageHistory`, `loadMoreMessages`, `loadThreadReplies` (the methods that issue HTTP and feed the notifier from server data) — has no direct test in `chat_notifier_test.dart`; coverage is via `chat_cold_start_hydration_test.dart` for one specific scenario only. Codegen migration is a refactor; the right time to discover that ref-graph changes broke an http-driven path is before the user sees it.
- **Fix**: Add `chat_notifier_loadMessageHistory_test.dart` with a fake `http.Client` override, exercising: 200 response → messages added in chronological order; 404 → state unchanged; conversation-already-loaded short-circuit. The provider container override pattern is already established in `chat_notifier_test.dart:12-31`.
- **Effort**: medium
