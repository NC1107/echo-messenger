# 02 — Message-Loss Surface Area

**This is the headline file.** Every code path where a message can be silently lost, permanently undecryptable, or wedge the session, with severity, repro scenario, and what (if anything) mitigates it today.

## Triage summary

| # | Finding | Severity | Test today? | Closes via |
|---|---------|----------|-------------|------------|
| H1 | Secure-storage read failure cascades | **HIGH** | None on failure leg | Audit P0-1 |
| H2 | Fire-and-forget OTP re-upload silently drops | **HIGH** | Happy path only | Audit P0-2 |
| H3 | Skipped-key window exhaustion wedges session | **HIGH** *(was MED)* | Rust only | Audit P1-1 |
| M1 | Group rotation has no liveness guarantee | **MED** *(conditional on default-on)* | Server 409 only | Audit P1-2 / Design Phase 3 |
| M2 | Group envelope decrypt falls back to plaintext-key | **MED** | None | Audit P1-3 |
| M3 | Multi-device session keying fallback can collide | **MED** | Partial | None scheduled |
| M4 | Session-state torn write across crash | **MED** *(new)* | None | New P1 |
| L1 | Wire-format errors throw with placeholder | **LOW** | Solid | Working as designed |
| L2 | Identity-key change blocks send until accepted | **LOW** | Solid | Working as designed |
| L3 | `decryptHistoryMessage` returns null on failure | **LOW** | None (by design) | Working as designed |
| L4 | Isolate JSON round-trip failure mode | **LOW** *(new)* | None | Optional P2 instrumentation |
| L5 | Keys-regenerated wipe is loud | **LOW** | Indirect | Working as designed |

Severity legend:
- **HIGH** — user-visible data loss with no automatic recovery and no clear UI signal.
- **MED** — recoverable but requires user action (retry, key reset, contact peer) and the user may not realise action is needed.
- **LOW** — user sees a clear placeholder ("[Could not decrypt…]") and the next message in the conversation will succeed.

*Test-surface column reflects the QA review pass that ran in parallel to this audit; "None on failure leg" means a happy-path test exists but the failure-leg branch is uncovered.*

## HIGH — Secure-storage read failure cascades to permanent decrypt failure

- **Where**: `crypto_service.dart:841` (session reload on cache miss) → `secure_key_store.dart:85–91` (rethrows on storage read error).
- **Scenario**: Linux libsecret keyring locked at the moment of decrypt; macOS Keychain prompt denied; Android Keystore biometric timeout. `_decryptNormalMessage` throws `"No session for $sessionKey"`. User sees `[Could not decrypt…]` for that message — and every subsequent message in the same conversation because the in-memory session is now gone too.
- **Mitigation today**: None automatic. Restarting the app re-reads the keyring; if it succeeds the session reloads.
- **Why HIGH**: User has no in-app prompt to unlock the keyring, no banner explaining what failed, and no "retry decrypt" affordance. The conversation appears permanently broken.

## HIGH — Fire-and-forget OTP re-upload silently drops the heal attempt

- **Where**: `crypto_service.dart:730` — `.catchError((upErr) { debugPrint(...); })` on the background `uploadKeys()` call triggered by initial-decrypt failure.
- **Scenario**: Sender hits a stale prekey bundle, recipient throws `InitialDecryptFailedException` (line 717), recipient schedules a background `uploadKeys()` to refresh, that upload fails (network blip, server 500). The next message from the same sender fails identically, forever, until the user happens to re-open settings and re-upload keys.
- **Mitigation today**: `debugPrint` only — no UI surface, no exponential retry, no banner.
- **Why HIGH**: This is exactly the "permanently undecryptable" case you fear, and the only signal is a console log.
- **Related**: GitHub issue #662.

## HIGH — Skipped-key window exhaustion wedges the session

*(Originally graded MED; bumped to HIGH after the security review pointed out the practical scenarios.)*

- **Where**: `signal_session.dart:289–292` — `if (recvCounter + maxSkip < until) throw "Too many skipped messages"`. `maxSkip = 1000` (`signal_protocol.dart:36`).
- **Scenario**: Peer sends 1001 messages while you are offline / unable to fetch. On reconnect, the ratchet refuses to skip far enough forward. The session wedges; you cannot decrypt any of those messages.
- **Practical exposure**: an active group-DM with 5 chatty peers (where every member's ratchet receives every other member's outputs as out-of-order) can burn 1000 messages over a long weekend. This is not a "weeks-offline" scenario; it is a "Friday evening to Monday morning with a busy chat" scenario.
- **Mitigation today**: None automatic. Recoverable via `forceResetSession()` (audit P1-1), which the user has no way to discover today.
- **Why HIGH**: User has no UI affordance, no in-app explanation, no retry. The recovery API exists but is buried in code. Conforms to Signal spec — Signal also caps skipped keys — but Signal's recovery UX is worse than nothing; ours is "nothing".

## MED — Group rotation has no liveness guarantee

- **Where**: `group_crypto_service.dart:performRotation`; server-side `routes/group_keys.rs` enforces `(conversation_id, key_version) UNIQUE` (first-writer-wins).
- **Scenario**: A rotation is triggered (membership change). All currently-online members crash before any of them completes `performRotation`. The group has a stale key version with no active rotator. New messages encrypted at the old version still decrypt for current members; new messages at a new version can't be sent until someone retries.
- **Mitigation today**: Rotation re-triggers on next event. No formal leader election.
- **Why MED**: Real but rare; covered by GitHub issue #658 and explicitly called out in CLAUDE.md "Known Limitations".

## MED — Group envelope decrypt falls back to plaintext-key on unwrap error

- **Where**: `group_crypto_service.dart:225` — on envelope unwrap failure, the code falls back to treating the wrapped blob as a legacy plaintext key.
- **Scenario**: An envelope was wrapped with the wrong recipient's pubkey (rotation race), or the wrapping changed format and we mis-detect it. We unwrap as plaintext, get random bytes, then use them as an AES key — every subsequent group message "decrypts" to garbage with no sanity check downstream.
- **Mitigation today**: AEAD authentication tag would catch the corruption on actual decrypt, but the user-facing surface is "[Could not decrypt…]" for every group message, not "your group key is wrong, fetch a new one".
- **Why MED**: AEAD prevents silent acceptance of bad plaintext, but the user sees an unrecoverable group rather than a "rotate now" affordance.

## MED — Session-state torn write across a mid-encrypt crash

*(Surfaced by the security review of this audit; not in the initial pass.)*

- **Where**: `crypto_service.dart:846–849` — `_saveSession` writes session state to secure storage **before** the isolate hop and **again** with the post-state after. Two separate writes; not atomic.
- **Scenario**: App crashes between the pre-save and post-save (e.g. OS kills the process for memory pressure, hard reboot). The on-disk state is the pre-encrypt snapshot. On relaunch, the session is "valid" and accepts a fresh send — but the in-flight wire we already emitted to the server used the *post*-state. Recipient receives a wire keyed at counter N+1; sender's next encrypt uses counter N. Wedge.
- **Mitigation today**: Pre-save is the write-ahead intent. If the process dies *before* the pre-save, no message left the device — safe. If it dies *between* pre-save and the WS frame leaving, the recipient never sees it — safe. The unsafe window is "WS frame sent, post-save not yet committed" — narrow but not zero.
- **Why MED**: Window is small in practice. The Hive transaction model on Dart is best-effort. There is no test that exercises this (QA review confirmed). File as P1; instrument first, then decide if a true write-ahead log is justified.

## MED — Multi-device session keying fallback can collide

- **Where**: `crypto_service.dart:636` — preferred session key is `userId:deviceId`, with fallback to `userId` when no device-specific session exists.
- **Scenario**: Two devices for the same user. Device A sends from `userId:devA`; Device B has never seen a `userId:devB` entry so falls back to `userId`. Both rows can race to write the same `userId` slot during migration.
- **Mitigation today**: New sessions are always created at `userId:deviceId`; the fallback is read-only on existing data.
- **Why MED**: The race is narrow (only during the upgrade path from a pre-multi-device state). On fresh installs the fallback is never taken.

## LOW — Wire-format errors throw with clear UI placeholder

- **Where**: `signal_session.dart:194, 201, 206` (header parse), `signal_protocol.dart:150, 163` (AEAD).
- **Scenario**: Truncated message, header length mismatch, AEAD tag check fails (corruption or wrong key).
- **Mitigation today**: All paths throw and surface `[Could not decrypt - encryption keys may be out of sync]` in the bubble. Future messages in the same session succeed (the ratchet advances on send, not on receive of a bad message).
- **Why LOW**: User has a visible signal, conversation continues.

## LOW — Identity-key change blocks send until accepted

- **Where**: `crypto_service.dart:453–464` — throws `IdentityKeyChangedException`. UI handler at `home_screen.dart:1014` shows a verify-and-accept banner.
- **Scenario**: Peer reset their device or was compromised. Local TOFU record disagrees with what the server returned.
- **Mitigation today**: Banner forces user to acknowledge before any new message can be sent. Already-received messages still decrypt with the old key.
- **Why LOW**: Working as designed; the banner is the *whole point* of TOFU.

## LOW — Isolate JSON round-trip failure surfaces as decrypt failure

*(Surfaced by the security review of this audit.)*

- **Where**: `crypto_service.dart:856` — decrypt runs in a `compute()` isolate. Session JSON is serialized into the isolate, decrypted, then re-serialized back.
- **Scenario**: Malformed state blob, OOM in the isolate, isolate-spawn failure (rare on desktop, more common on web). The isolate hop throws; caller renders `[Could not decrypt…]` even though the on-disk session is fine.
- **Mitigation today**: Caller path re-tries on the next message implicitly because session reloads from disk on next decrypt.
- **Why LOW**: Recoverable. Worth instrumenting so we know how often it happens in production.

## LOW — `decryptHistoryMessage` returns null on failure

- **Where**: `crypto_service.dart:939` — `catch (_) { return null; }`.
- **Scenario**: Backfilling a conversation from server history; one entry can't be decrypted.
- **Mitigation today**: Intentional. The bubble was already rendered as `[Could not decrypt…]` on first receive; backfill is allowed to skip silently.
- **Why LOW**: Working as designed.

## LOW — Keys-regenerated wipe is loud

- **Where**: `init_extension.dart:327` (sets `_keysWereRegenerated = true`); `crypto_service.dart:1020` (`_sessions.clear()`).
- **Scenario**: First launch after a wipe / re-install / explicit reset. Identity changed, prior sessions are unrecoverable.
- **Mitigation today**: Conditional snackbar in `splash_screen.dart:228` — *only* shown when `MessageCache.entryCount() > 0`, so fresh installs don't see the scary banner.
- **Why LOW**: Working as designed; loud signal where it matters.

## Summary count

- **HIGH**: 3 — secure-storage read failure, fire-and-forget OTP heal, skipped-key window exhaustion.
- **MED**: 4 — group rotation liveness *(conditional on default-on)*, envelope decrypt fallback, multi-device keying fallback, session-state torn write.
- **LOW**: 5 — wire-format errors, identity-key change, history backfill, isolate failure, keys-regenerated wipe.

All three HIGH items are recoverable in principle but invisible to the user today. The full prioritisation lands in [`06-recommendations.md`](06-recommendations.md).
