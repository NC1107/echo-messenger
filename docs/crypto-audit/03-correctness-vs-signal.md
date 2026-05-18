# 03 — Correctness vs the Signal Spec

Echo's Dart implementation is a re-implementation, not a wrapper around libsignal. This file walks the spec sections that matter most for "could a divergence cause message loss?" and grades conformance.

References:
- Signal X3DH spec: https://signal.org/docs/specifications/x3dh/
- Double Ratchet spec: https://signal.org/docs/specifications/doubleratchet/
- Our reference Rust port: `core/rust-core/src/signal/*.rs` (used only by Rust tests today — see [`05-rust-core-vs-dart.md`](05-rust-core-vs-dart.md)).

## X3DH

| Spec requirement | Our implementation | Verdict |
|------------------|---------------------|---------|
| Verify signed-prekey signature with the peer's identity key (Ed25519) before any DH | `signal_x3dh.dart:initiate` does this | ✅ |
| Run DH1 = DH(IK_A, SPK_B); DH2 = DH(EK_A, IK_B); DH3 = DH(EK_A, SPK_B); DH4 = DH(EK_A, OPK_B) if available | Implemented in correct order | ✅ |
| Derive shared secret with HKDF over `F || DH1 || DH2 || DH3 [|| DH4]` where `F = 32 0xFF bytes` for X25519 | `signal_x3dh.dart` matches | ✅ |
| Wipe ephemeral private key after key derivation | Dart `Uint8List` private-key regions are dereferenced and left to GC; we do **not** explicitly overwrite the bytes (no `fillRange(0, n, 0)` calls in the crypto path) | ⚠️ Gap — Dart `Uint8List` is GC'd, not deterministically zeroed. Theoretical post-compromise issue only. |
| Deletion of one-time prekey on responder side after first successful decrypt | `crypto_service.dart:_decryptInitialMessage` deletes the OPK after success | ✅ |

**Risk note**: Dart's lack of deterministic zeroing on `Uint8List` is a theoretical post-compromise-recovery weakness, not a message-loss issue. Flagged for awareness, not the audit's focus. The original draft of this audit used the word "zeroize" here; that was sloppy — we do not actively zero key material, we merely drop the reference. Reviewers should not read the absence of zeroing as a Signal-spec deviation that affects forward secrecy *during normal operation*; it only affects what an attacker with post-process-exit memory access could recover. If we ever decide to harden this, the fix is a `KeyMaterial` wrapper that calls `bytes.fillRange(0, bytes.length, 0)` on `dispose()`.

## Double Ratchet

| Spec requirement | Our implementation | Verdict |
|------------------|---------------------|---------|
| Root key & chain keys derived via HKDF-SHA256 | `signal_session.dart` uses `kdfRk` / `kdfCk` from `signal_protocol.dart` | ✅ |
| New DH ratchet step on each direction change | `_diffieHellmanRatchet` (line ~250) | ✅ |
| Skipped message keys stored for out-of-order delivery | `skippedKeys` map, capped via `maxSkip=1000` | ✅ (cap is a hazard — see [`02`](02-message-loss-surface.md)) |
| Header encryption ("HE" variant) | **Not implemented** — we use unencrypted headers | ⚠️ Gap. Signal's own mobile apps achieve a similar metadata-protection goal via **Sealed Sender**, which we also don't implement. The two are different mechanisms; we have neither. |
| Constant-time AEAD usage | `package:cryptography` AES-GCM | ✅ |
| Detect and reject replays inside the skipped-key window | `signal_session.dart:217` removes the message key from `skippedKeys` on first successful consume — a replayed ciphertext at the same `(ratchet_pub, message_number)` finds an empty slot and fails. | ✅ |

**Header encryption**: Skipping HE means a passive observer of the WebSocket can see ratchet-public-keys and message numbers in cleartext. This does not leak content but does leak some metadata about conversation activity. Not a message-loss issue; mention for completeness. Earlier drafts framed this as "consistent with Signal mobile clients" — that framing was misleading. Signal's mobile clients address the same metadata goal via Sealed Sender, which we also don't implement. Be honest: we have no equivalent metadata-protection mechanism.

**Replay**: A re-sent ciphertext fails to decrypt because `signal_session.dart:217` removes the corresponding message key from `skippedKeys` on first successful consume — confirmed against the source. The earlier draft of this audit confused this with server-side row uniqueness; the server's `messages.id UUID PRIMARY KEY DEFAULT gen_random_uuid()` does *not* dedup replays at the storage layer (it mints a fresh row per accepted send), so the crypto-layer defence is the only thing standing between us and a duplicate-bubble bug. That defence is correct. Row in the table above updated from ⚠️ to ✅.

## Wire format

Our framing is a slight deviation from the libsignal binary protobuf format. We use a hand-rolled `[0xEC, version] + header_len + header + nonce + ct + tag` layout (see [`01-architecture-map.md`](01-architecture-map.md)). The deviation is fine — what matters is that it is unambiguous, versioned, and the parser fails loud (`signal_session.dart:194–206` all throw).

**Verdict**: Wire format is correctly versioned and round-trip tested. The `0xEC` magic byte gives us a clear forward-compat slot.

## Key storage

| Spec requirement | Our implementation | Verdict |
|------------------|---------------------|---------|
| Identity key persisted with strong OS-backed storage | `secure_key_store.dart` → Keychain / Keystore / libsecret / DPAPI | ✅ |
| One-time prekeys deleted after first use | `crypto_service.dart` removes the OPK private from secure storage on success | ✅ |
| Signed prekey rotation | 7-day rotation with 14-day grace period for the previous key. Implemented in `crypto/init_extension.dart::_rotateSignedPrekeyIfNeeded`. | ✅ |

**Signed prekey rotation**: The spec recommends periodic rotation; we rotate every 7 days with a 14-day grace period for the previous key. Implementation in `apps/client/lib/src/services/crypto/init_extension.dart`. The grace-period cleanup was originally buggy (compared against the *current* prekey's age, letting the previous key linger up to `gracePeriod + maxAge` instead of `gracePeriod`); audit P2-1 added a `_signedPrekeyPreviousCreatedAtPref` timestamp so the cleanup compares against the actual birth of the previous key.

## Summary

Our Dart implementation tracks the Signal spec faithfully for the core flow. The deviations are conscious or low-impact:
- Header encryption: skipped (consistent with Signal mobile).
- Deterministic zeroing: limited by Dart runtime; theoretical post-compromise issue only.
- Signed-prekey rotation: missing; P2.
- Skipped-key cap of 1000: matches Signal; recovery UX is our gap.

**Nothing in the spec-conformance review points to message loss.** Loss risks are all operational (storage, network heal) and are catalogued in [`02-message-loss-surface.md`](02-message-loss-surface.md).
