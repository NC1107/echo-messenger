# 01 — Architecture Map

A factual inventory. No grading — that's [`02-message-loss-surface.md`](02-message-loss-surface.md)'s job.

## File inventory (1:1 protocol)

| File | Lines | Role |
|------|-------|------|
| `apps/client/lib/src/services/signal_protocol.dart` | 246 | Low-level primitives: HKDF-SHA256, AES-256-GCM, `MessageHeader` serialization (40 bytes). Defines `const int maxSkip = 1000`. |
| `apps/client/lib/src/services/signal_x3dh.dart` | 166 | X3DH — 3-DH or 4-DH (with OTP) handshake. Returns 32-byte shared secret. |
| `apps/client/lib/src/services/signal_session.dart` | 418 | Double Ratchet state machine. DH ratchet step, chain-key evolution, skipped-key buffer (capped at `maxSkip=1000`), wire packing. |
| `apps/client/lib/src/services/session_cache.dart` | 183 | In-memory LRU (200 entries) + 24h TTL. Zero-on-eviction. Non-destructive — disk is source of truth. |
| `apps/client/lib/src/services/crypto_service.dart` | 1623 | The orchestrator. X3DH setup, session lifecycle, OTP replenishment, identity-key TOFU, multi-device keying, pre-crash session write-ahead, corrupted-session quarantine. |
| `apps/client/lib/src/providers/crypto_provider.dart` | 400 | Riverpod notifier. `initAndUploadKeys()`, error tracking (`keysUploadFailed`, `keysWereRegenerated`), group-key API surface. |
| `apps/client/lib/src/services/secure_key_store.dart` | 100+ | Platform-abstraction over FlutterSecureStorage (Keychain / Keystore / libsecret / DPAPI / encrypted localStorage on web). |
| `apps/client/lib/src/services/group_crypto_service.dart` | 474 | AES-256-GCM group key, per-member ECDH-wrapped envelopes, rotation. Wire prefix `GRP1:`. |
| `core/rust-core/src/signal/**/*.rs` | ~1.5k | Reference Rust implementation. Exercised by Rust tests only — the Flutter client never crosses an FFI boundary into this code. See [`05-rust-core-vs-dart.md`](05-rust-core-vs-dart.md). |

## Wire format reference

Three message shapes are framed over WebSocket, base64-encoded:

```
V2 Initial (with OTP):
  [0xEC, 0x02] + identity_pub(32) + ephemeral_pub(32) + otp_id(4 LE) + ratchet_wire

V1 Initial (no OTP — sender exhausted recipient's OTP pool):
  [0xEC, 0x01] + identity_pub(32) + ephemeral_pub(32) + ratchet_wire

Normal:
  header_len(4 LE) + header(40) + nonce(12) + ciphertext + tag(16)
```

`MessageHeader` (40 bytes) = `ratchet_pub(32) + prev_chain_length(4 LE) + message_number(4 LE)`.

Parser entry points:
- Magic prefix dispatch — `crypto_service.dart:654–660`.
- Header deserialization — `signal_session.dart:194–206`.
- OTP-id extraction (V2 path) — `crypto_service.dart:776–794`.

## 1:1 send path

UI tap → `ChatInputBar.sendMessage` → `websocketProvider.sendDmMessage` → `_encryptMessageImpl` → `getOrCreateSession(peerUserId)` → (cache miss: `GET /api/keys/bundle/{peer}` → `X3DH.initiate` → `SignalSession.initAlice`) → `session.encrypt(plaintext)` → `_buildInitialWire` if first message → base64 → WS `send_message`.

## 1:1 receive path

WS `message_relayed` → `_handleMessageRelayed` → magic-prefix check → either `_decryptInitialMessage` (V1/V2: load OTP private key → `X3DH.respond` → `SignalSession.initBob` → `session.decrypt`) or `_decryptNormalMessage` (reload session from cache/disk → `session.decrypt` in isolate) → plaintext to UI, or `InitialDecryptFailedException` → `[Could not decrypt — encryption keys may be out of sync]` placeholder.

## Cold-start path

`CryptoNotifier.initAndUploadKeys` → check secure storage for identity → either resume or `_keysWereRegenerated = true` + clear all sessions → `drainPendingDecryptQueue()` for messages queued during init.

## Group-message state

Working today: AES-256-GCM with random 12-byte nonce, ECDH-wrapped envelopes per member, `(conversation_id, key_version) UNIQUE` constraint on the server. See [`../group-e2e-design/01-current-state.md`](../group-e2e-design/01-current-state.md) for the rotation flow and what's missing.
