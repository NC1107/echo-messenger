# 06 — Recommendations

Prioritised P0 / P1 / P2 with concrete next steps. Each item links back to the finding in [`02-message-loss-surface.md`](02-message-loss-surface.md), [`03-correctness-vs-signal.md`](03-correctness-vs-signal.md), [`04-performance.md`](04-performance.md), or [`05-rust-core-vs-dart.md`](05-rust-core-vs-dart.md).

## P0 — Do this sprint (closes the three HIGH message-loss risks)

*(Reframed after the security review re-graded MED-1 skipped-key to HIGH and pointed out that all three P0/P1 items share the same UX pattern — "typed exception → provider flag → banner → retry action". They should ship as one bundled PR, not three sequential ones. The estimate moved from "2 PRs / 300 LOC" to "1 PR / ~400 LOC".)*

### P0-1 — Surface keyring-lock failures to the user

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Secure-storage read failure cascades to permanent decrypt failure" (H1).
- **What**: In `secure_key_store.dart`, distinguish "no key found" from "storage unavailable" via a typed `StorageUnavailableException`. In `crypto_provider.dart`, expose a new state flag `secureStorageUnavailable`. In `home_screen.dart` / chat bubbles, when this flag is set, render a top-of-conversation banner: *"Echo can't read its encryption keys. Unlock your system keyring and tap Retry."* The cascade-survival guarantee — in-memory `_sessions` LRU entry must survive a transient throw — is the actual fix; the banner is just observability.
- **Estimate**: ~200 LOC client. No server changes.
- **Risk**: Low. Banner is additive; cascade-survival is one early-return.
- **Test acceptance (per QA review)** — these tests must exist and pass before the PR is reviewable:
  1. `secure_key_store_test.dart::read_throws_typed_StorageUnavailableException_on_PlatformException` — new exception type, distinguished from "key absent".
  2. `crypto_provider_test.dart::secureStorageUnavailable_flag_set_when_decrypt_hits_keyring_lock` — state-transition unit test using the throwing `FakeSecureKeyStore`.
  3. `crypto_service_test.dart::session_reload_failure_does_not_zero_in_memory_session` — **the actual fix**. After a transient throw, the in-memory entry must survive so a retry can succeed.
  4. `chat_panel_test.dart::keyring_locked_banner_visible_when_flag_set` — widget test for the banner + Retry button.
  5. `chat_provider_state_test.dart::retry_after_unlock_decrypts_pending_queue` — integration: the `drainPendingDecryptQueue` path.
- **Repro recipe**: extend `test/helpers/fake_secure_key_store.dart` with a `Map<String, Exception> _throwOnRead`. Inject via `SecureKeyStore.instance = …`. No physical device needed.

### P0-2 — Make OTP heal observable + retried

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Fire-and-forget OTP re-upload silently drops the heal attempt" (H2). Also closes GitHub #662.
- **What**: Replace the `.catchError(debugPrint)` at `crypto_service.dart:730` with: (a) exponential-backoff retry up to 5 attempts; (b) on final failure, surface `keysUploadFailed=true` in the crypto provider and show the existing settings-screen banner; (c) write a row to a `key_health` log so we can spot recurring failures.
- **Estimate**: ~100 LOC client.
- **Risk**: Low. Failure path becomes louder, not different.
- **Test acceptance (per QA review)**:
  1. `crypto_service_test.dart::otp_heal_retries_5_times_with_exponential_backoff_on_500` — `MockHttpClient` returns 500 N times; verify N invocations spaced by expected delays via `FakeAsync`.
  2. `crypto_service_test.dart::otp_heal_sets_keysUploadFailed_after_terminal_failure` — after 5 failures, `cryptoProvider.state.keysUploadFailed == true`.
  3. `crypto_service_test.dart::otp_heal_clears_flag_on_eventual_success` — failures-then-success path resets the flag.
  4. `crypto_service_test.dart::next_decrypt_from_same_sender_after_heal_success_succeeds` — the end-state the user cares about.
  5. `privacy_section_test.dart::settings_banner_visible_when_keysUploadFailed` — existing banner at `privacy_section.dart:756` stays wired.
- **Repro recipe**: existing test at `crypto_service_test.dart:677` already stubs `POST /api/keys/upload`. Flip the stub to return 500. The whole recipe is a 30-line variant of the existing test.

### P0-3 — "Reset session" affordance for wedged conversations

*(Promoted from P1-1 to P0 after the security review re-graded skipped-key exhaustion to HIGH.)*

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Skipped-key window exhaustion wedges the session" (H3) + general "things go wrong silently" fear.
- **What**: When a conversation has produced 3 consecutive `[Could not decrypt…]` placeholders, surface a per-conversation banner: *"Encryption is out of sync with [peer]. Resetting will recover, but messages from before now may not decrypt."* with a "Reset session" button calling `forceResetSession`.
- **Estimate**: ~100 LOC client. Small per-conversation counter, banner widget, button wired to the already-existing `forceResetSession`.
- **Risk**: Low. Pattern matches P0-1/P0-2; the recovery API already exists.
- **Test acceptance**:
  1. `chat_provider_test.dart::three_consecutive_decrypt_failures_set_outOfSync_flag`.
  2. `chat_panel_test.dart::outOfSync_banner_visible_with_reset_button`.
  3. `crypto_service_test.dart::forceResetSession_clears_session_and_quarantines_old_state`.

### PR shape

All three above ship as **one bundled PR**, ~400 LOC, ~15 tests. They share `crypto_provider` state-flag plumbing and the chat-panel banner slot; splitting them creates three PRs that all touch the same files. Per `/echo-fix` discipline: land the failing tests as a first commit on the PR, then the fix commits that flip them green. Reviewer sees the regression net before the fix.

## P1 — Next sprint (closes MED risks)

### P1-1 — Multi-client simulation test harness *(promoted from P2)*

*(Promoted by the QA review. L4 (group rotation liveness) and L9 (crash recovery) from [`../group-e2e-design/05-message-loss-analysis.md`](../group-e2e-design/05-message-loss-analysis.md) cannot be unit-tested. Building this harness first — separate from any group E2E feature work — gives us the infrastructure to test the failure modes that matter most, reusable across all future concurrency work.)*

- **What**: An in-process Dart harness that drives N fake `GroupCryptoService` instances against a shared mock server, with a kill-switch per client. Used to test split-brain, leader-only-online, follower-only-online, all-online, and partition scenarios.
- **Estimate**: 3 days infra investment.
- **Risk**: Low. Pure test code; doesn't touch production.
- **Why first**: The design's Phase 3 (server-led leader election) names this test surface but does not name the harness. The harness has to land before Phase 3 can credibly call itself "tested".

### P1-2 — Catch the group-envelope unwrap-fallback footgun

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Group envelope decrypt falls back to plaintext-key on unwrap error" (M2).
- **What**: At `group_crypto_service.dart:225`, add an AEAD-style sanity check: encrypt a known-magic byte string with the candidate key and verify it decrypts. If not, treat as fatal envelope error rather than plaintext fallback. Surface the failure with a "rotate group key" affordance.
- **Estimate**: 1 day.

### P1-3 — Session-state torn-write instrumentation

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → M4 "Session-state torn write across a mid-encrypt crash".
- **What**: Add a write-ahead intent flag to the pre-save in `crypto_service.dart:846`. On startup, if the flag is set and no post-save committed, log a structured event and (optionally) discard the half-state to force re-establishment. Instrument first — decide on the real fix once we have data on how often this happens.
- **Estimate**: 1 day instrumentation + a sprint of soak before deciding on full WAL.

### P1-4 — Telemetry on the four crypto hot paths

- **Closes**: [`04-performance.md`](04-performance.md) → "We don't measure performance".
- **What**: Add `Timeline.timeSync` markers around `encrypt`, `decrypt`, `X3DH.initiate`, `groupCrypto.performRotation`. No metrics export needed; this is for profiler captures only.
- **Estimate**: half a day.

### Note on group rotation liveness (former P1-2)

Group rotation liveness was an earlier P1 item. It is now design work that lives in [`../group-e2e-design/03-recommended-protocol.md`](../group-e2e-design/03-recommended-protocol.md) §"Rotation flow" and Phase 3 of [`../group-e2e-design/04-migration-plan.md`](../group-e2e-design/04-migration-plan.md). The audit no longer tracks it separately.

## P2 — Later (cleanup, hygiene, drift defence)

### P2-1 — Signed-prekey rotation

- **Closes**: [`03-correctness-vs-signal.md`](03-correctness-vs-signal.md) → "Signed prekey rotation missing".
- **What**: Rotate the server-side signed prekey on a 30-day schedule, falling back to the previous one for in-flight initial messages (we already have that fallback path at `crypto_service.dart:813`).
- **Estimate**: 2–3 days client + server. Touches `routes/keys.rs` and a new background task.
- **Risk**: Medium. Needs careful interop testing against in-flight clients.

### P2-2 — Cross-implementation wire-compat test

- **Closes**: [`05-rust-core-vs-dart.md`](05-rust-core-vs-dart.md) → "Two implementations, no contract".
- **What**: Shared `core/rust-core/testdata/wire-vectors/*.json`. A `gen_vectors.rs` binary target emits seeded vectors; Rust consumer at `core/rust-core/tests/wire_compat.rs` and Dart consumer at `apps/client/test/services/signal_wire_compat_test.dart` both load the JSON and assert byte-equality. Wire to existing `lint-test-rust` and `lint-test-flutter` CI gates from `.github/workflows/dev-build.yml`.
- **Estimate**: **5 days** (revised from 2 by the QA review). Bulk of the work is seeded-RNG injection in both impls — Rust uses `rand_core::OsRng`, Dart uses `package:cryptography`'s internal RNG — neither is currently seedable without code changes. Plan accordingly.

### P2-3 — Eliminate JSON round-trip on the decrypt isolate hop

- **Closes**: [`04-performance.md`](04-performance.md) → "two JSON round-trips per decrypt".
- **What**: Move to a binary state format (or use `Isolate.exit` to skip the response serialize). Profile first.
- **Estimate**: 1–2 days, contingent on profile evidence.

### P2-4 — Decide whether to keep `core/rust-core/src/signal/`

- **Closes**: [`05-rust-core-vs-dart.md`](05-rust-core-vs-dart.md) → "Delete or formalise".
- **What**: After P2-2 has run for a sprint and we have confidence in the compat test, decide whether to delete the Rust port or to invest in growing it. **No action needed before then.**

## Items explicitly out of scope

- **Switching to libsignal-client**: too disruptive given current product priorities. Reconsider in 6 months.
- **Header encryption (Signal HE variant)**: small metadata improvement, no message-loss impact.
- **Deterministic zeroing of `Uint8List`**: limited by Dart runtime; no practical impact unless we suspect host compromise, in which case we have bigger problems.

## What "done" looks like for this audit

- P0-1, P0-2, P0-3 implemented as one bundled PR → all three HIGH findings closed.
- P1-1 multi-client harness landed before any group E2E feature work.
- P1-2, P1-3, P1-4 filed as GitHub issues (one issue each, labelled `crypto`, `severity:medium`).
- P2 items added to the roadmap doc.
- This audit is referenced from `docs/encryption.md`, `docs/SECURITY.md`, and `CLAUDE.md` so future contributors find it.

The group E2E design proposal lives next door: [`../group-e2e-design/`](../group-e2e-design/).
