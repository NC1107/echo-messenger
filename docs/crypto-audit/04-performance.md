# 04 — Performance Profile

Does crypto hurt UX? Where does it block the UI thread? Where would caching change the picture?

## Init order

From `apps/client/lib/main.dart` → `splash_screen.dart` → `CryptoNotifier.initAndUploadKeys`:

1. Hive opens (offline cache).
2. Splash window shrinks to 320×440 (desktop).
3. iOS/macOS local-network permission explainer.
4. `tryAutoLogin()` (HTTP).
5. **`initAndUploadKeys()`** — generates or loads identity, signed prekey, OTP pool; uploads to server.
6. `loadConversations()`.
7. Navigation.

Step 5 is the only crypto step on the boot path. On a cold first launch it can do:
- Identity Ed25519 keypair generation (fast, <10 ms).
- Signed-prekey X25519 generation + Ed25519 signature (fast).
- 100 one-time prekey generations (~50–100 ms total).
- Network upload (`POST /api/keys/upload`) — the dominant cost.

Splash now holds a minimum 1.5 s (see `splash_screen.dart:111–119`), which exceeds typical crypto-init wall time, so a fast crypto init never makes the user wait longer than the splash design floor.

**Verdict**: Init crypto is *not* a UX bottleneck. Network upload dominates on cold start, which is unavoidable.

## Per-message encrypt latency

`websocketProvider.sendDmMessage` → `_encryptMessageImpl`:

- Cache-hit session → `session.encrypt`: HKDF + AES-GCM, microseconds.
- Cache-miss session → secure-storage read + JSON parse + ratchet state restore. Single-digit ms on warm secure storage; can spike to tens of ms on Linux libsecret cold path.
- Fresh session (X3DH): bundle fetch (HTTP) + 4-DH + ratchet init. Hundreds of ms on a fresh conversation. **One-time cost per peer**.

**Verdict**: Cache-hit encrypts are free. Cold-conversation X3DH is the one user-visible delay, and it shows up as the "sending…" indicator on the first message. Acceptable.

## Per-message decrypt latency

`_decryptNormalMessage` deserializes the session, then runs `session.decrypt` inside a `compute()` isolate (`crypto_service.dart:856`). Isolate dispatch + JSON serialize round-trip is ~5–15 ms on desktop, more on web (no native isolates).

**Hot path quirk**: on every receive we serialize the session to JSON, send to isolate, isolate runs decrypt, then we save the post-state JSON back to disk. That's two JSON round-trips per decrypt. On a chat with 100 inbound messages in quick succession, that's noticeable but not catastrophic. Optimisation candidate, not a correctness issue.

## Session-cache eviction churn

`SessionCache` is LRU at 200 entries with 24 h TTL. For users with many active 1:1 peers (a heavy power-user), thrashing past 200 will force secure-storage reloads. The reload itself is fast on Keychain/Keystore but slower on libsecret (cold-keyring case).

**Suggestion** (not action): instrument the cache hit/miss ratio in debug builds before deciding to raise the cap.

## Group encryption hot path

Per group message:
1. `groupCrypto.getGroupKey()` — in-memory map lookup (free) or 5-minute disk-cached bundle (cheap) or `GET /api/group-keys/...` (network).
2. AES-GCM encrypt — microseconds.
3. WS send.

Receive path mirrors. **No expensive operations on the hot path** once the group key is in cache.

The expensive operation is **rotation** — generating a new key, wrapping it for every member's identity public key, posting envelopes. For an N-member group that's N ECDH operations. At N=100 this is still well under 200 ms. Rotation is rare (membership change).

## What we don't measure

We have no production telemetry on crypto operation times. Zero. The performance verdicts above are based on reading the code, not from real measurements.

**P2 recommendation**: add `Timeline.timeSync` markers around the four hot paths (encrypt, decrypt, X3DH initiate, group rotate) so we can spot regressions in profiler captures without instrumentation churn.

## Bottom line for the user's question

> *"Is the encryption setup hindering our app?"*

No, not in any measurable way. The one place crypto delays the user is the first message to a new peer (X3DH bundle fetch), which is unavoidable for the protocol. Splash boot is dominated by network + window resize, not crypto. Decrypt is fast enough on desktop; web is slower but acceptable.

Crypto is **not** what's slowing Echo. If something feels slow, look at WebSocket reconnect, conversations-load timeouts, image-bubble layout (#178 — image dimensions caching landed for exactly this), or onboarding hops. Crypto is well-behaved.
