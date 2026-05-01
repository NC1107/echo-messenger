# Technical Debt

Last updated: 2026-05-01 (audit verification + remaining fixes on `dev`)

## Summary

| Severity | Open | Fixed since 2026-04-30 | Total |
|---|---|---|---|
| Critical | 0 | 8 | 8 |
| High | ~13 | ~21 | 34 |
| Medium | 68 | 0 | 68 |
| Low | 22 | 0 | 22 |
| **Total** | **~103** | **~29** | **132** |

Findings come from a multi-agent review (security, backend, frontend, devops, code-quality, test-quality, performance, architecture) of the full repo on the `dev` branch. Full per-finding evidence including code excerpts and exact file:line refs lives in `.claude/state/audit-project/review-queue-20260430-161802.md`.

Security findings are intentionally tracked here rather than as public GitHub issues until fixes land or a coordinated disclosure plan is in place.

---

## Critical — all resolved on `dev`

All 8 criticals from the 2026-04-30 audit have been fixed. Verification on 2026-05-01 against current `dev`:

- **CRIT-1 ✓ Fixed** — LiveKit voice token IDOR. `apps/server/src/routes/voice.rs:80-130` now derives the LiveKit `room` claim from the validated `conversation_id`/`channel_id` only, after the membership check on the same value. `body.room` is no longer trusted.
- **CRIT-2 ✓ Fixed** — e2e specs use real assertions. `tests/e2e/local_full.spec.ts:9-14` `check()` helper now wraps `expect(...).toBe(true)`. `tests/e2e/crypto_dm_test.spec.ts` uses real `expect()` throughout (test 1 bundle, test 2 send/receive + crypto-error guards, test 3 post-restart bundle/open/send-no-error, test 4 key persistence).
- **CRIT-3 ✓ Fixed** — `?token=` removed; ws-ticket flow used. `tests/e2e/local_full.spec.ts:163-184` mints via `POST /api/auth/ws-ticket` and connects with `?ticket=`. `|| true` removed.
- **CRIT-4 ✓ Fixed** — Double-Ratchet limits enforced and tested. `core/rust-core/src/signal/ratchet.rs` uses `saturating_add` (line 367), enforces `MAX_SKIPPED_KEYS` global cap (line 379), and rejects oversized headers/blobs in tests `test_skip_limit_exceeded_rejects` (line 737) and `test_deserialize_rejects_oversized_skipped_keys` (line 778).
- **CRIT-5 ✓ Fixed** — JWT expiry has unit coverage. `apps/server/src/auth/jwt.rs:140` `test_expired_token_is_rejected` mints `exp: now-3600` and asserts rejection.
- **CRIT-6 ✓ Fixed** — LiveKit signaling on loopback. `infra/docker/docker-compose.prod.yml:77` binds `127.0.0.1:7880:7880`; Traefik fronts `livekit.echo-messenger.us` with TLS.
- **CRIT-7 ✓ Fixed** — trufflehog explicit base/head. `.github/workflows/security.yml` splits `pull_request` and `push` events with explicit ranges for push.
- **CRIT-8 ✓ Fixed** — SonarCloud no longer runs on `pull_request`. `.github/workflows/sonarcloud.yml:11-13` restricts to `push: branches: [main, dev]` so PR head code never sees `SONAR_TOKEN`.

---

## High

### Server / API / Database
- **HIGH-1 ✓ Fixed** — WS replay no longer pre-marks delivered. Per-device delivery ledger landed (#584); `deliver_undelivered_messages` is cursor-paginated and only marks delivered after `send_to_device` returns true.
- **HIGH-2 ✓ Fixed** — `tokio::select!` joins the receive/send halves at `apps/server/src/ws/handler.rs:270`.
- **HIGH-3 ✓ Fixed** — `change_password` argon2 calls run under `spawn_blocking` at `apps/server/src/routes/users.rs:452-468` (verify + hash both wrapped).
- **HIGH-4 ✓ Fixed** — `upload_group_key` runs sentinel + envelopes inside one transaction (`apps/server/src/routes/group_keys.rs:140-165`) with `ON CONFLICT` idempotency on duplicate version.
- **HIGH-5 ✓ Fixed** — `upload_group_key` validates each `envelope.user_id` against the in-tx member set and caps the request at 10 000 envelopes (`group_keys.rs:117-160`).
- **HIGH-6 ✓ Fixed** — `link_preview` enforces `MAX_HTML_BYTES`, content-type filter, and content-length pre-check; reads via `bytes_stream` with hard cap (`apps/server/src/routes/link_preview.rs:150-200`).
- **HIGH-7 ✓ Fixed** — `REGISTRATION_OPEN` enforced at `apps/server/src/routes/auth.rs:146` via `crate::config::registration_open()` with regression tests in `config.rs:241-260`.
- **HIGH-8 ✓ Fixed** — list endpoints bind explicit `LIMIT` constants (`LIST_CONTACTS_LIMIT`, `LIST_BLOCKED_LIMIT`, `LIST_PENDING_LIMIT` = 1 000 each) at `apps/server/src/db/contacts.rs:11-13,118,156,215`.
- **HIGH-9 — Partially fixed** — `delete_group_dependents` (`apps/server/src/main.rs:401-`) now opens one transaction and logs every failure arm, but still issues 9 explicit DELETEs rather than calling `force_delete_conversation` + relying on full cascade FKs. Effort: small (after the cascade-FK migration extends to the missing tables).
- **HIGH-10 ✓ Fixed** — slow-consumer eviction. `try_send_tracked` in `apps/server/src/ws/hub.rs:166-205` rolls a per-(user,device) full-counter window and force-unregisters at `SLOW_CONSUMER_FULL_THRESHOLD`.
- **HIGH-11 ✓ Fixed** — cursor-paginated `deliver_undelivered_messages`; `UNDELIVERED_PAGE_SIZE = 100` constant in `db/messages.rs`.

### Performance
- **HIGH-12 ✓ Fixed** — fanout serializes JSON once and ships `WsMessage::Text(json.into())` so hub-side clones are O(1) over `Bytes`. See `apps/server/src/ws/message_service.rs:441-471,704-756`.
- **HIGH-13 ✓ Fixed** — reply-count via single aggregating subquery (LEFT JOIN) instead of correlated LATERAL re-execution. `apps/server/src/db/messages.rs:225-235,299-309,525`.
- **HIGH-14 ✓ Fixed** — `get_conversation_auth_context` (issue #691) returns kind/role/is_public in one round-trip. `apps/server/src/db/groups.rs:386-410`.
- **HIGH-15 ✓ Fixed** — `cache_sweep` periodic task spawned from `main.rs:93`; `invalidate_member_cache` exposed at `ws/typing_service.rs:118` and called from add/remove/role-change paths.

### Client (still open)
- **HIGH-16** `ChatPanel.build` is 249 lines with side effects in `addPostFrameCallback` from `build` — `widgets/chat_panel.dart:2233`. Move to `initState`/`didUpdateWidget`; replace `ref.watch(chatProvider)` with `select`.
- **HIGH-17** `voice_lounge_screen.dart` is 2,683 lines with two `build` methods of 195 + 193 lines — extract `_VoiceDock`, `_VoiceParticipantGrid`, `_VoiceFocusedTile` into `widgets/voice_lounge/`.

### Code quality (still open)
- **HIGH-18** 123 copies of identical "DB error → AppError::internal" closure across `routes/*.rs`. Note: `.db_ctx(...)` extension landed and is in use across `voice.rs`, `group_keys.rs`, `users.rs` etc.; remaining call sites still need migration. Track as in-progress sweep.

### Tests (still open)
- **HIGH-19** 32 sites use `tokio::time::sleep(200ms)` for "drain pending" — `ws_messaging.rs:30`, `ws_events.rs:78`, +30 more. Use `tokio::time::timeout` waiting on specific events.
- **HIGH-20** FK CASCADE migration has no integration test — `migrations/20260412000000_cascade_conversation_fks.sql`. Add `delete_conversation_cascades_to_children`.
- **HIGH-21** Migrations run once per process; tests share DB row state — `tests/common/mod.rs:23-49`. Per-test transaction or per-test schema.
- **HIGH-22** 6 skipped optimistic-update tests in `chat_panel_test.dart` (#670). Resolve or rewrite without widget pump.
- **HIGH-23** e2e tests use viewport-relative pixel clicks for login — `crypto_dm_test.spec.ts:88,131`. Use `getByRole`.
- **HIGH-24** e2e specs use 5-8s `waitForTimeout` for Flutter boot (58 occurrences). Use `waitForSelector('flt-semantics')`.

### DevOps
- **HIGH-25 ✓ Fixed** — Server Dockerfile copies migrations from the real path (`apps/server/migrations`); `.github/workflows/release.yml:519` likewise updated; the stale `apps/server/src/migrations/` directory was deleted in this audit pass.
- **HIGH-26 ✓ Fixed** — root `.dockerignore` exists.
- **HIGH-27 ✓ Fixed** — `HEALTHCHECK` in server Dockerfile (`apps/server/Dockerfile:54`) and `healthcheck:` in compose stacks.
- **HIGH-28** Web Docker base `nginx:alpine` not pinned by digest. Pin all base images by `@sha256:...`.
- **HIGH-29** No SBOM, no provenance attestation, no artifact signing in release pipeline.
- **HIGH-30** No resource limits on any production service in `docker-compose.prod.yml`. Add `mem_limit`, `cpus`, `logging` rotation.
- **HIGH-31** Postgres has no WAL/PITR; backups are local-only. Add WAL archiving + off-host target + restore test.
- **HIGH-32** `delete_group_dependents` swallows `Err` silently — see HIGH-9 note: tx errors now logged, but the per-table delete loop still continues on individual failures.
- **HIGH-33** `e2e.yml` soft-fails both test lanes (`continue-on-error: true`) — 60 CPU-min/run for zero signal.

### Contract / cross-language (still open)
- **HIGH-34** Wire-format magic constants duplicated across Rust core, Rust server, Dart client. Single source manifest + codegen.

---

## Medium

68 medium-severity items spanning input validation, secret rotation, cache invalidation, file-streaming, primitive-obsession enums, regex hoisting, presence broadcast hygiene, missing service layer, migration consolidation, secret-in-env vs docker secrets, etc. Full list with file:line references in the review queue file.

Highlights:
- Filesystem error details leak via `format!("...: {e}")` (security-expert #8) — `routes/{media,groups,users}.rs`
- Disappearing-TTL conversation default not clamped (security-expert #6) — `routes/messages.rs:711`
- Push-token registration unbounded (security-expert #5)
- Search wildcards `%`/`_` not escaped in `list_public_groups` (security-expert #9)
- Membership cache invalidation missing on add/ban/role paths (backend #10)
- `media::download` reads full file into memory (backend #15) — use `ReaderStream` (note: per-recent commit `4cd1f7d perf(server): stream media upload/download to avoid 100MB RAM buffer` this may already be addressed; needs verification)
- `ice_config` returns static long-lived TURN credentials (backend #16) — should be HMAC-time-limited
- `update_profile` unbounded email/phone/website/timezone (backend #17)
- 5 inline regex-in-loop sites in client widgets (perf #13-15)
- 33 schema migrations with no consolidation (arch #5)
- REST handlers reach into `db::*` directly — no service layer (arch #1)
- `core/rust-core/src/api.rs` referenced by CLAUDE.md doesn't exist (arch #3) — VERIFIED. Update CLAUDE.md known-limitations.
- `ws/handler.rs` (851 lines) mixes lifecycle, parse, dispatch, voice signaling, canvas (arch #7)
- `ws_message_handler.dart` (901 lines) is god orchestrator (arch #8)
- 30+ duplicated `is_member` + role-check pairs across routes (arch #20)
- Soft-delete docs say `is_deleted` but code uses `deleted_at` (CLAUDE.md drift) — VERIFIED
- Negative-input tests missing for unicode/oversized/null on every REST endpoint (test-quality #23)
- WS-ticket race not concurrency-tested (test-quality #17)
- cargo-deny `multiple-versions = "warn"` not "deny"; RUSTSEC ignore lists drift between deny.toml and CI (devops #12-13)
- No CodeQL workflow (devops #14)
- lefthook missing pre-push deny check + light secret scan (devops #18)

---

## Low

22 nits including:
- `WsTicketRequest::device_id` defaults to 0 — collides with first-real-device id (backend #23)
- `RatchetState`'s 11 private fields with implicit invariants (code-quality #29)
- `push.rs` `unwrap()` on `SystemTime::now().duration_since(UNIX_EPOCH)` (code-quality #15)
- `lib.rs` no crate-level `//!` doc (code-quality #23)
- `valid_url_returns_preview` is `#[ignore]` and never runs (test-quality #26)
- `scripts/run.sh:32` `JWT_SECRET="dev-secret"` (10 chars; CLAUDE.md panics ≥32) — VERIFIED (devops #29)
- Forward-secrecy ratchet test conflates two properties (test-quality #24)
- nginx CSP `connect-src wss: https:` overly broad (devops #27)
- AppState lumps everything; should use `FromRef` (arch #12)
- SignalSession serialization not interop with Rust core (arch #18)

---

## Frontend audit gap

The dedicated frontend reviewer agent stalled on the 2026-04-30 run. Code-quality and perf+arch agents covered Dart code at the file-size, regex, rebuild, and lifecycle levels, but the following remain unexamined:
- Full Riverpod provider lifecycle (scoping, ref.read in build, dispose ordering)
- BuildContext use after async gaps
- A11y semantics labels / 44x44 tap targets (some covered by recent #495-498 batch)
- Theme `ThemeExtension` dark/light parity
- GoRouter redirect loops, deep-link auth gaps
- Hive box lifecycle / schema drift
- WS reconnect backoff specifics
- Web `?server=` query-param handling

A focused frontend re-run is recommended before GA.

---

## Progress Tracking

- [x] CRIT-1: LiveKit voice token IDOR
- [x] CRIT-2: e2e specs `console.log` instead of assertions
- [x] CRIT-3: WS `?token=` in test seed
- [x] CRIT-4: Double-Ratchet MAX_SKIP cap untested + unbounded skipped_keys
- [x] CRIT-5: JWT expiry unit test missing
- [x] CRIT-6: LiveKit 7880 public bind
- [x] CRIT-7: trufflehog push misconfig
- [x] CRIT-8: SonarCloud token exposure to PR head
- [x] HIGH-1..15 (server/API/db/perf): all resolved on dev
- [x] HIGH-25, HIGH-26, HIGH-27 (devops): resolved on dev
- [ ] HIGH-9 follow-up: collapse `delete_group_dependents` once cascade FK migration extends
- [ ] HIGH-16, HIGH-17, HIGH-18 (client/code-quality refactors)
- [ ] HIGH-19..24 (test discipline)
- [ ] HIGH-28..34 (devops + cross-language)
- [ ] MEDIUM (68 items)
- [ ] LOW (22 items)
- [ ] Frontend audit re-run
