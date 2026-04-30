# Technical Debt

Last updated: 2026-04-30 (multi-agent audit on `dev`)

## Summary

| Severity | Count |
|---|---|
| Critical | 8 |
| High | 34 |
| Medium | 68 |
| Low | 22 |
| **Total** | **132** |

Findings come from a multi-agent review (security, backend, frontend, devops, code-quality, test-quality, performance, architecture) of the full repo on the `dev` branch. Full per-finding evidence including code excerpts and exact file:line refs lives in `.claude/state/audit-project/review-queue-20260430-161802.md`.

Security findings are intentionally tracked here rather than as public GitHub issues until fixes land or a coordinated disclosure plan is in place.

---

## Critical

### CRIT-1 — LiveKit voice token IDOR
**File**: `apps/server/src/routes/voice.rs:86-130`
The `room` claim minted into the LiveKit JWT is taken from `body.room.or(body.channel_id).or(body.conversation_id)`, but the membership check at line 117 runs against `body.conversation_id.or(body.channel_id)`. An attacker who is a member of any conversation can request `{room: "<victim-room>", conversation_id: "<their-own>"}` and receive a token granting `roomJoin/canPublish/canSubscribe` on the victim's room.
**Fix**: derive `room` from the validated `conversation_id`/`channel_id` only; drop or canonicalize `body.room`.
**Effort**: small.

### CRIT-2 — e2e specs use `console.log` in place of assertions
**Files**: `tests/e2e/local_full.spec.ts:9-11,115`, `tests/e2e/crypto_dm_test.spec.ts:254-259`
Both specs report PASS/FAIL via `console.log` calls; the suite reports green even when the assertions would have failed. The crypto-error detector in particular logs detected errors and continues.
**Fix**: replace each `check(name, ok)` and error-`console.log` with `expect(...).toBe(true)` / `expect(errors).toEqual([])`.
**Effort**: small.

### CRIT-3 — Test seed uses forbidden `?token=` WS query param
**File**: `tests/e2e/local_full.spec.ts:148-149`
CLAUDE.md mandates ticket-based WS auth (`?ticket=` only). Test uses `?token=...` and `|| true` swallows any failure.
**Fix**: `POST /api/auth/ws-ticket` then `?ticket=`. Drop `|| true`.
**Effort**: small.

### CRIT-4 — Double-Ratchet `MAX_SKIP=1000` cap is not tested + `skipped_keys` map can grow unbounded
**Files**: `core/rust-core/src/signal/ratchet.rs:363,510`, `apps/client/lib/src/services/signal_session.dart:289`
The DoS guard against a malicious peer sending `message_number = u32::MAX` exists but has zero coverage in either Rust or Dart. The deserialize-side `num_skipped > MAX_SKIP` gate is also untested. Across DH-ratchet steps `skipped_keys` has no global cap, and the comparison `recv_counter + MAX_SKIP < until` can panic in debug builds on overflow.
**Fix**: add `test_skip_limit_exceeded_rejects` and `test_deserialize_rejects_oversized_skipped_keys`; mirror in Dart `crypto_test.dart`. Cap `skipped_keys.len()` globally (e.g. 2000 entries with oldest-evict). Switch to `saturating_add`.
**Effort**: small.

### CRIT-5 — JWT expiry rejection has no unit test
**File**: `apps/server/src/auth/jwt.rs:87`
Existing tests cover wrong-secret and roundtrip, but no test mints a `Claims { exp: now-1 }` and asserts `validate_token` rejects it. A regression that accepts expired tokens would not be caught by the unit suite.
**Fix**: add `test_expired_token_is_rejected`.
**Effort**: small.

### CRIT-6 — LiveKit signaling port 7880 published on 0.0.0.0
**File**: `infra/docker/docker-compose.prod.yml:66-77`
Port 7880 (LiveKit HTTP/WebSocket signaling) is bound to all interfaces, bypassing Traefik and TLS termination. Direct access lets anyone hit the API-key-protected endpoint.
**Fix**: bind to `127.0.0.1` (or `echo-internal` network) and proxy via Traefik with TLS. Document required host firewall rules for the media UDP ports (50000-50200).
**Effort**: medium.

### CRIT-7 — trufflehog secret scan misconfigured for `push` events
**File**: `.github/workflows/security.yml:33-42`
The action defaults to scanning a single commit (or the working tree) on `push` events without explicit `base`/`head`. Historical secrets added in a single squash commit can be missed.
**Fix**: pass `base: ${{ github.event.before }}` and `head: ${{ github.event.after }}` for push events.
**Effort**: small.

### CRIT-8 — SonarCloud workflow exposes `SONAR_TOKEN` to PR head code
**File**: `.github/workflows/sonarcloud.yml:3-6,23`
`pull_request` (not `pull_request_target`) runs the head's `cargo test` and the SonarCloud scanner with `SONAR_TOKEN` in env. A malicious PR can dump the token via `build.rs`, modified test code, or any third-party action.
**Fix**: split into a `pull_request` job that produces coverage artifacts (no token) and a `workflow_run`-triggered job that consumes them with the token; or restrict to `push` only.
**Effort**: medium.

---

## High

### Server / API / Database
- **HIGH-1** WS message marked `delivered=true` before client confirms — `apps/server/src/ws/message_service.rs:978-1009`. Mid-air loss window if TCP dies between `tx.send` and socket flush.
- **HIGH-2** WS receive/send loops not linked by `tokio::select!` — `apps/server/src/ws/handler.rs:202-209,258-263`. Half can outlive the other.
- **HIGH-3** `change_password` runs Argon2 on async runtime — `apps/server/src/routes/users.rs:462,468`. Stalls Tokio worker for 50-150ms.
- **HIGH-4** `upload_group_key` is non-transactional — `apps/server/src/routes/group_keys.rs:126-161`. Partial state leaves some members unable to decrypt.
- **HIGH-5** `upload_group_key` doesn't verify envelope recipients are members — `apps/server/src/routes/group_keys.rs:85-186`. Hostile admin can pollute the table for arbitrary user IDs.
- **HIGH-6** `link_preview` reads body unbounded — `apps/server/src/routes/link_preview.rs:170-174`. OOM / gzip-bomb DoS.
- **HIGH-7** `REGISTRATION_OPEN` advertised but never enforced — `apps/server/src/routes/auth.rs:140-167`. Closed self-hosted instances still accept registrations.
- **HIGH-8** List endpoints lack `LIMIT` — `db/contacts.rs:86-103,118-138,181-195`, `db/groups.rs:180-194,268-278`. Unbounded responses.
- **HIGH-9** `delete_group_dependents` is 9-statement non-transactional — `apps/server/src/main.rs:224-241`. Use `force_delete_conversation` + cascade FKs.
- **HIGH-10** `mpsc(256)` outbound queue silently drops on full — `ws/hub.rs:109-129`, `handler.rs:194`. Stuck consumer never disconnected.
- **HIGH-11** `get_undelivered LIMIT 200` truncates large offline backlogs — `db/messages.rs:226-252`. No continuation cursor.

### Performance
- **HIGH-12** Per-recipient JSON re-serialization clones full body N times in fanout — `ws/message_service.rs:704-738,756`, `ws/typing_service.rs:246`, `main.rs:128,217`. `WsMessage::Text` is `Bytes`-backed; clone the message, not the String.
- **HIGH-13** Reply-count correlated subquery O(N·M) in `get_messages` and `get_undelivered` — `db/messages.rs:198,237,732`. Convert to `LEFT JOIN LATERAL`.
- **HIGH-14** `is_member` + `get_conversation_kind` + `get_member_role` triple round-trip per group route. Add `get_conversation_auth_context` returning all three in one query.
- **HIGH-15** Membership/typing/conv-kind caches never evict — `ws/typing_service.rs:20-30`. Periodic sweep + invalidate on add/ban/role-change paths.

### Client
- **HIGH-16** `ChatPanel.build` is 249 lines with side effects in `addPostFrameCallback` from `build` — `widgets/chat_panel.dart:2233`. Move to `initState`/`didUpdateWidget`; replace `ref.watch(chatProvider)` with `select`.
- **HIGH-17** `voice_lounge_screen.dart` is 2,683 lines with two `build` methods of 195 + 193 lines — extract `_VoiceDock`, `_VoiceParticipantGrid`, `_VoiceFocusedTile` into `widgets/voice_lounge/`.

### Code quality
- **HIGH-18** 123 copies of identical "DB error → AppError::internal" closure across `routes/*.rs`. Add `trait DbErrCtx` extension.

### Tests
- **HIGH-19** 32 sites use `tokio::time::sleep(200ms)` for "drain pending" — `ws_messaging.rs:30`, `ws_events.rs:78`, +30 more. Use `tokio::time::timeout` waiting on specific events.
- **HIGH-20** FK CASCADE migration has no integration test — `migrations/20260412000000_cascade_conversation_fks.sql`. Add `delete_conversation_cascades_to_children`.
- **HIGH-21** Migrations run once per process; tests share DB row state — `tests/common/mod.rs:23-49`. Per-test transaction or per-test schema.
- **HIGH-22** 6 skipped optimistic-update tests in `chat_panel_test.dart` (#670). Resolve or rewrite without widget pump.
- **HIGH-23** e2e tests use viewport-relative pixel clicks for login — `crypto_dm_test.spec.ts:88,131`. Use `getByRole`.
- **HIGH-24** e2e specs use 5-8s `waitForTimeout` for Flutter boot (58 occurrences). Use `waitForSelector('flt-semantics')`.

### DevOps
- **HIGH-25** Server Dockerfile copies migrations from wrong path — `apps/server/Dockerfile:37` says `apps/server/src/migrations`; real path is `apps/server/migrations/`. The `src/migrations/` dir contains stale `001_initial.sql` etc. Either fix the path or drop the COPY (`sqlx::migrate!` embeds at compile time) and remove the stale dir.
- **HIGH-26** No `.dockerignore` files anywhere — multi-GB build contexts and risk of copying secrets.
- **HIGH-27** No `HEALTHCHECK` in server Docker image and no `healthcheck:` in compose — Traefik routes to dead containers until TCP refuses.
- **HIGH-28** Web Docker base `nginx:alpine` not pinned by digest. Pin all base images by `@sha256:...`.
- **HIGH-29** No SBOM, no provenance attestation, no artifact signing in release pipeline.
- **HIGH-30** No resource limits on any production service in `docker-compose.prod.yml`. Add `mem_limit`, `cpus`, `logging` rotation.
- **HIGH-31** Postgres has no WAL/PITR; backups are local-only. Add WAL archiving + off-host target + restore test.
- **HIGH-32** `delete_group_dependents` swallows `Err` silently — `apps/server/src/main.rs:141,224-241`. Log every Err arm.
- **HIGH-33** `e2e.yml` soft-fails both test lanes (`continue-on-error: true`) — 60 CPU-min/run for zero signal.

### Contract / cross-language
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
- `media::download` reads full file into memory (backend #15) — use `ReaderStream`
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

The dedicated frontend reviewer agent stalled. Code-quality and perf+arch agents covered Dart code at the file-size, regex, rebuild, and lifecycle levels, but the following remain unexamined:
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

- [ ] CRIT-1: LiveKit voice token IDOR
- [ ] CRIT-2: e2e specs `console.log` instead of assertions
- [ ] CRIT-3: WS `?token=` in test seed
- [ ] CRIT-4: Double-Ratchet MAX_SKIP cap untested + unbounded skipped_keys
- [ ] CRIT-5: JWT expiry unit test missing
- [ ] CRIT-6: LiveKit 7880 public bind
- [ ] CRIT-7: trufflehog push misconfig
- [ ] CRIT-8: SonarCloud token exposure to PR head
- [ ] HIGH-1..34: see above
- [ ] MEDIUM (68 items)
- [ ] LOW (22 items)
- [ ] Frontend audit re-run
