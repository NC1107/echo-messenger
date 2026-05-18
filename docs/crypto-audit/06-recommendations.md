# 06 — Recommendations

Prioritised P0 / P1 / P2 with concrete next steps. Each item links back to the finding in [`02-message-loss-surface.md`](02-message-loss-surface.md), [`03-correctness-vs-signal.md`](03-correctness-vs-signal.md), [`04-performance.md`](04-performance.md), or [`05-rust-core-vs-dart.md`](05-rust-core-vs-dart.md).

## P0 — Do this sprint (closes the two HIGH message-loss risks)

### P0-1 — Surface keyring-lock failures to the user

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Secure-storage read failure cascades to permanent decrypt failure".
- **What**: In `secure_key_store.dart`, distinguish "no key found" from "storage unavailable" and bubble the latter up. In `crypto_provider.dart`, expose a new state flag `secureStorageUnavailable`. In `home_screen.dart` / chat bubbles, when this flag is set, render a top-of-conversation banner: *"Echo can't read its encryption keys. Unlock your system keyring and tap Retry."*
- **Estimate**: 1–2 days. ~200 LOC client only. No server changes.
- **Risk**: Low. Banner is additive.

### P0-2 — Make OTP heal observable + retried

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Fire-and-forget OTP re-upload silently drops the heal attempt". Also closes GitHub #662.
- **What**: Replace the `.catchError(debugPrint)` at `crypto_service.dart:730` with: (a) exponential-backoff retry up to 5 attempts; (b) on final failure, surface `keysUploadFailed=true` in the crypto provider and show the existing settings-screen banner; (c) write a row to a `key_health` log so we can spot recurring failures.
- **Estimate**: 1 day client. ~100 LOC.
- **Risk**: Low. Failure path becomes louder, not different.

## P1 — Next sprint (closes MED risks and the user's "finickiness" feel)

### P1-1 — Recovery affordance for wedged sessions

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Skipped-key window exhaustion wedges the session" + the user's overall fear that things go wrong silently.
- **What**: When a conversation has produced more than N (say 3) consecutive `[Could not decrypt…]` placeholders, surface a per-conversation banner: *"Encryption is out of sync with [peer]. Resetting will recover, but messages from before now may not decrypt."* with a "Reset session" button calling `forceResetSession`.
- **Estimate**: 2 days. Needs a small per-conversation counter and a banner widget.
- **Risk**: Low.

### P1-2 — Group rotation liveness

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Group rotation has no liveness guarantee". Also closes #658.
- **What**: This is design work — see [`../group-e2e-design/03-recommended-protocol.md`](../group-e2e-design/03-recommended-protocol.md) for the proposed leader-election approach.

### P1-3 — Catch the group-envelope unwrap-fallback footgun

- **Closes**: [`02-message-loss-surface.md`](02-message-loss-surface.md) → "Group envelope decrypt falls back to plaintext-key on unwrap error".
- **What**: At `group_crypto_service.dart:225`, add an AEAD-style sanity check: encrypt a known-magic byte string with the candidate key and verify it decrypts. If not, treat as fatal envelope error rather than plaintext fallback. Surface the failure with a "rotate group key" affordance.
- **Estimate**: 1 day.

### P1-4 — Telemetry on the four crypto hot paths

- **Closes**: [`04-performance.md`](04-performance.md) → "We don't measure performance".
- **What**: Add `Timeline.timeSync` markers around `encrypt`, `decrypt`, `X3DH.initiate`, `groupCrypto.performRotation`. No metrics export needed; this is for profiler captures only.
- **Estimate**: half a day.

## P2 — Later (cleanup, hygiene, drift defence)

### P2-1 — Signed-prekey rotation

- **Closes**: [`03-correctness-vs-signal.md`](03-correctness-vs-signal.md) → "Signed prekey rotation missing".
- **What**: Rotate the server-side signed prekey on a 30-day schedule, falling back to the previous one for in-flight initial messages (we already have that fallback path at `crypto_service.dart:813`).
- **Estimate**: 2–3 days client + server. Touches `routes/keys.rs` and a new background task.
- **Risk**: Medium. Needs careful interop testing against in-flight clients.

### P2-2 — Cross-implementation wire-compat test

- **Closes**: [`05-rust-core-vs-dart.md`](05-rust-core-vs-dart.md) → "Two implementations, no contract".
- **What**: Shared `testdata/wire-vectors/`; Dart emits, Rust consumes, and vice versa. Wire to both `cargo test` and `flutter test` CI jobs.
- **Estimate**: 2 days. Bulk of the work is the harness, not the vectors themselves.

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

- P0-1 and P0-2 implemented → both HIGH findings closed.
- P1 items filed as GitHub issues (one issue each, labelled `crypto`, `severity:medium`).
- P2 items added to the roadmap doc.
- This audit is referenced from `docs/encryption.md` so future contributors find it.

The group E2E design proposal lives next door: [`../group-e2e-design/`](../group-e2e-design/).
