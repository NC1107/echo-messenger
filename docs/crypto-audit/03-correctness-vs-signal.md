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
| Wipe ephemeral private key after key derivation | Dart's GC + zeroize on `Uint8List` regions | ⚠️ Best-effort — Dart `Uint8List` is GC'd, not deterministically zeroed |
| Deletion of one-time prekey on responder side after first successful decrypt | `crypto_service.dart:_decryptInitialMessage` deletes the OPK after success | ✅ |

**Risk note**: Dart's lack of deterministic zeroing on `Uint8List` is a theoretical post-compromise-recovery weakness, not a message-loss issue. Flagged for awareness, not the audit's focus.

## Double Ratchet

| Spec requirement | Our implementation | Verdict |
|------------------|---------------------|---------|
| Root key & chain keys derived via HKDF-SHA256 | `signal_session.dart` uses `kdfRk` / `kdfCk` from `signal_protocol.dart` | ✅ |
| New DH ratchet step on each direction change | `_diffieHellmanRatchet` (line ~250) | ✅ |
| Skipped message keys stored for out-of-order delivery | `skippedKeys` map, capped via `maxSkip=1000` | ✅ (cap is a hazard — see [`02`](02-message-loss-surface.md)) |
| Header encryption ("HE" variant) | **Not implemented** — we use unencrypted headers | ⚠️ Conscious choice; Signal mobile clients also skip HE |
| Constant-time AEAD usage | `package:cryptography` AES-GCM | ✅ |
| Detect and reject replays inside the skipped-key window | Map lookup on `(ratchet_pub, message_number)` — replay would silently re-derive the same plaintext | ⚠️ |

**Header encryption**: Skipping HE means a passive observer of the WebSocket can see ratchet-public-keys and message numbers in cleartext. This does not leak content but does leak some metadata about conversation activity. Not a message-loss issue; mention for completeness.

**Replay**: A re-sent ciphertext within the skipped-key window will produce the same plaintext (correct) and bubble it as a "new" message (incorrect — UI dedup happens upstream by server message ID). The server enforces unique IDs, so we believe this is closed off at the storage layer, but a hostile sender bypassing the server could theoretically inject. Action item: file a follow-up to confirm message-ID uniqueness is enforced before the crypto layer ever sees a duplicate.

## Wire format

Our framing is a slight deviation from the libsignal binary protobuf format. We use a hand-rolled `[0xEC, version] + header_len + header + nonce + ct + tag` layout (see [`01-architecture-map.md`](01-architecture-map.md)). The deviation is fine — what matters is that it is unambiguous, versioned, and the parser fails loud (`signal_session.dart:194–206` all throw).

**Verdict**: Wire format is correctly versioned and round-trip tested. The `0xEC` magic byte gives us a clear forward-compat slot.

## Key storage

| Spec requirement | Our implementation | Verdict |
|------------------|---------------------|---------|
| Identity key persisted with strong OS-backed storage | `secure_key_store.dart` → Keychain / Keystore / libsecret / DPAPI | ✅ |
| One-time prekeys deleted after first use | `crypto_service.dart` removes the OPK private from secure storage on success | ✅ |
| Signed prekey rotation | Manual / not yet implemented — same signed prekey lives forever | ⚠️ |

**Signed prekey rotation**: The spec recommends periodic rotation. We don't rotate. Impact: an attacker who compromises the server's stored signed prekey and historical OPKs could decrypt past sessions (no forward secrecy *before* the first DH ratchet step). This is a P2 issue, not a message-loss issue. Filed under [`06-recommendations.md`](06-recommendations.md) "P2".

## Summary

Our Dart implementation tracks the Signal spec faithfully for the core flow. The deviations are conscious or low-impact:
- Header encryption: skipped (consistent with Signal mobile).
- Deterministic zeroing: limited by Dart runtime; theoretical post-compromise issue only.
- Signed-prekey rotation: missing; P2.
- Skipped-key cap of 1000: matches Signal; recovery UX is our gap.

**Nothing in the spec-conformance review points to message loss.** Loss risks are all operational (storage, network heal) and are catalogued in [`02-message-loss-surface.md`](02-message-loss-surface.md).
