# Technical Debt

Last updated: 2026-04-11

## Summary
**Total Issues**: 85 | Critical: 4 (1 fixed) | High: 22 (15 fixed) | Medium: 38 (2 fixed) | Low: 21

## Fixed This Session
- [x] Argon2 blocks async executor — wrapped in `spawn_blocking`
- [x] SSRF in link preview — private IP blocking added
- [x] Unbounded WS mpsc channels — bounded to 256
- [x] `get_undelivered` no LIMIT — capped at 200
- [x] sqlx unique-constraint error maps ALL to "Username taken" — constraint-specific messages
- [x] 13 UX quick wins (input bar, error states, accessibility, session recovery)
- [x] Rate limit on refresh + ws-ticket endpoints
- [x] Referrer-Policy + Permissions-Policy headers (replaced X-XSS-Protection)
- [x] Silent DB error swallowing — logged on 8 broadcast paths
- [x] Rate limiter Mutex → DashMap (lock-free)
- [x] Pool connections 100 → 30 + acquire/idle timeouts
- [x] broadcast_presence fetches IDs only
- [x] Dead code removed (set_conversation_encrypted)
- [x] message_device_contents device_id index
- [x] Unknown WS event type default logging
- [x] Multi-device encryption sync (from earlier task)

## Critical (Remaining)
- [ ] **Untested auth refresh token theft detection** — `apps/server/src/routes/auth.rs` — no integration tests for refresh flow (effort: small)
- [ ] **Untested rate limiter** — `apps/server/src/middleware/rate_limit.rs` — zero tests for brute-force protection (effort: small)
- [ ] **Untested WS ticket single-use** — `apps/server/src/routes/ws.rs` — ticket replay attack untested (effort: small)

## High — Security
- [ ] **File upload trusts client MIME** — `apps/server/src/routes/media.rs:26` — validate magic bytes with `infer` crate (effort: small)
- [ ] **CSP allows unsafe-inline/eval** — `apps/server/src/routes/mod.rs:263` — remove for XSS protection (effort: medium)
- [ ] **IP rate limit trusts X-Real-IP** — `apps/server/src/middleware/rate_limit.rs:76` — add trusted proxy CIDR (effort: small)
- [x] ~~No rate limit on refresh/ws-ticket~~ — FIXED
- [ ] **Peer identity key TOFU** — `apps/client/lib/src/services/crypto_service.dart:371` — no change detection on key swap (effort: medium)
- [ ] **Key upload no proof-of-possession** — `apps/server/src/routes/keys.rs:77` — stolen token allows key substitution (effort: large)
- [x] ~~Missing Referrer-Policy + Permissions-Policy headers~~ — FIXED

## High — Performance
- [ ] **5-6 sequential DB round-trips per WS message send** — `apps/server/src/ws/handler.rs:493` — consolidate queries (effort: medium)
- [ ] **Per-typing-event: 3-4 DB queries on every keystroke** — `apps/server/src/ws/handler.rs:974` — cache membership (effort: medium)
- [ ] **`find_or_create_dm_conversation` correlated subquery** — `apps/server/src/db/messages.rs:48` (effort: medium)

## High — Architecture
- [ ] **God-function `handle_send_message`** — 170 lines, 10 args — extract MessageService (effort: medium)
- [ ] **Multi-device offline delivery gap** — `deliver_undelivered_messages` sends canonical content, not per-device ciphertext (effort: medium)
- [ ] **Dual rate-limiting systems** — REST vs WS use incompatible in-memory stores (effort: medium)
- [ ] **SQL in WS handler** — `lookup_reply_context` bypasses db/ module (effort: small)

## High — Code Quality
- [x] ~~Silent DB error swallowing~~ — FIXED (logged on 8 broadcast paths)
- [ ] **`fanout_message` uses `unreachable!()` on live code path** — `apps/server/src/ws/handler.rs:870` (effort: small)
- [ ] **CryptoService is 1,516-line god class** — extract KeyStore, SessionManager, KeyUploadService (effort: large)
- [ ] **crypto_provider silent keyring degradation** — sends plaintext when keyring unavailable (effort: medium)

## High — Test Coverage
- [ ] **CryptoService has zero direct unit tests** — 1,516 lines untested (effort: large)
- [ ] **WS message handler (20+ event types) untested** — `ws_message_handler.dart` (effort: large)
- [ ] **Safety number generation untested** — MITM detection mechanism (effort: small)
- [ ] **No group RBAC tests** — 14 group management functions untested (effort: large)

## Medium (38 items)
See audit agent reports for full details. Key items:
- Missing DB indexes (user search, message_device_contents)
- OTP prekey upload needs transaction
- No API versioning (/api/v1/)
- Pool defaults consume 100% of PG connections
- `ConversationItem` calls SharedPreferences per list item
- Crypto decryption runs on UI thread (needs compute())
- Message dedup uses O(N) linear scan
- Channel kind uses raw string literals (no enum)
- Duplicate `get_messages` SQL query
- Rate limiter `Mutex<HashMap>` serializes all auth
- `broadcast_presence` fetches full ContactRow just for IDs
