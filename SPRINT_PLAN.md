# Sprint Plan — 4 sprints (8 weeks)

Last updated: 2026-04-30
Source: 2026-04-30 multi-agent audit (`TECHNICAL_DEBT.md`, 124 open findings) + existing GitHub backlog (116 open issues prior, 19 added by this audit).

## Conventions

- **Sprint length**: 2 weeks each, ~10 working days.
- **Capacity assumption**: one engineer full-time, or two engineers ~60% on roadmap items + ~40% on user-reported bugs. Adjust if your team is different — the relative ordering still applies.
- **Rule of thumb**: each sprint mixes one big-rock effort, several mediums, and a clutch of small-but-mechanical fixes so reviews stay manageable and merges flow steadily to `dev`.
- **Out of scope**: anything in `severity:low` or `ux:visual` polish backlog (#403/#404/#405) unless explicitly pulled in. The 8 audit criticals are already shipped on `dev` (see commits `b3d5eb9..417ad34`).

## Sprint themes

```
Sprint 1 — Beta-blocker correctness   (delivery semantics, crypto integrity)
Sprint 2 — Server reliability + perf  (hot-path allocs, list LIMIT, auth context)
Sprint 3 — Test infra + release pipe  (cascade tests, e2e cleanup, Docker hardening)
Sprint 4 — Architecture refactors     (god-widget split, WS handler split, Riverpod modernization)
```

---

## Sprint 1 — Beta-blocker correctness (weeks 1–2)

**Theme**: stop messages from getting silently dropped, lock down the remaining auth/crypto holes the audit found. Nothing here can wait for after launch.

| # | Issue | Severity | Effort | Notes |
|---|---|---|---|---|
| 1 | #521 + #634 | high (combined) | medium | Bundle the fix: introduce a per-connection ack queue so `delivered=true` only flips after client ack, AND when mpsc(256) is Full, count failures and force-disconnect the slow consumer. These two compound; one fix touches both surfaces. |
| 2 | #696 (H2) | high | medium | Wrap WS receive/send halves in `tokio::select!` so either ending tears both down. Drain `rx` with a short timeout before drop. |
| 3 | #689 (H11) | high | small | Paginate `get_undelivered` with cursor (`created_at > last_seen`). Re-arm on WS reconnect. |
| 4 | #687 (H4) | high | small | Wrap `upload_group_key` envelope storage in one tx. `ON CONFLICT DO UPDATE` for sentinel row. |
| 5 | #686 (H5) | high (sec) | small | Validate envelope `user_id`s against current group members. Cap envelope count. |
| 6 | #685 (H7) | high (sec) | small | Enforce `REGISTRATION_OPEN=false` in `register()`. Default closed. |
| 7 | #684 (H6) | high (sec) | medium | Stream `link_preview` body, abort at 256 KB, disable auto-decompression. |
| 8 | #697 (H3) | high | small | `change_password` Argon2 → `spawn_blocking`. Audit `reset_keys` for same. |

**Sprint 1 size**: ~8.5 days of medium work. Leaves ~1.5 days of slack for rework on rejected PRs.

**Exit criteria**:
- Cargo + Flutter test suites green; new ack-queue + concurrency tests added for #521/#634
- `gh issue close` on all 8 issues
- Soak `dev` for 48h with the new delivery semantics before merging to `main`

---

## Sprint 2 — Server reliability + perf foundations (weeks 3–4)

**Theme**: address the audit's perf findings before they bite at scale, and pay down the highest-leverage code-quality debt.

| # | Issue | Severity | Effort | Notes |
|---|---|---|---|---|
| 1 | #694 (H18) | high (cq) | medium | `DbErrCtx` extension trait. ~370 lines deleted across routes, +1 small util. Mechanical sweep — do this *first* in the sprint so other PRs use the new pattern. |
| 2 | #688 (H8) | high | medium | `LIMIT $N OFFSET $M` on contacts/groups list endpoints. Pagination params at route layer. |
| 3 | #678 + #638 | high+medium | small | Convert reply-count subqueries in `get_messages`/`get_undelivered` to `LEFT JOIN LATERAL`. Drop duplicate `idx_messages_reply_to` partial index in same migration. |
| 4 | #690 (H12) | high | small (loops) + medium (per-device) | `WsMessage::Text` once, clone the Bytes-backed message inside the loop. Per-device send loop: prefix-suffix prebuild instead of full re-serialize. |
| 5 | #691 (H14) | high | medium | `db::groups::get_conversation_auth_context` returning kind/role/is_public in one query. Sweep route handlers to the new helper. |
| 6 | #692 (H15) | high | small | Periodic 5-min eviction sweep on the three caches. Add `invalidate_member_cache` to add/ban/role-change paths. |
| 7 | #625 | high | medium | Tasks-of-spawn + JoinSet panic recovery. Replace 9-statement teardown with cascade-relying single DELETE in tx. Per-task cadence. |
| 8 | #680 + media download | high | medium | Stream uploads + downloads via `ReaderStream` / `bytes_stream`. Drops 100MB→8KB resident per request. Title rename per audit comment. |
| 9 | #436 (M64) | medium | small | Presence flap fix: gate "offline" on last-device-disconnect, "online" on first-device-register. |

**Sprint 2 size**: ~10 days. Tight; if H18 (#694) gets bikeshedded on naming, defer to Sprint 3.

**Exit criteria**:
- All `area:performance` issues from this list closed
- Latency on a 50k-row `list_contacts` benchmark drops by ≥80% (validate with `cargo bench` against a seeded test DB)
- `git grep "DB error in"` returns 0 hits in `apps/server/src/routes/`

---

## Sprint 3 — Test infrastructure + release pipeline (weeks 5–6)

**Theme**: fix the systemic test-quality issues the audit surfaced, harden the release pipeline, get the e2e suite trustworthy.

| # | Issue | Severity | Effort | Notes |
|---|---|---|---|---|
| 1 | #699 (H21) | high | large | Per-test transaction-rollback isolation in `tests/common/mod.rs`. Add `apps/server/tests/migrations.rs` that runs all 33 migrations against a fresh DB. Single biggest unlock for reliable Rust tests. |
| 2 | #698 (H20) | high | medium | `db_cascade.rs` integration test asserting CASCADE behavior on every child table. |
| 3 | #695 (H19) | high | medium | Sweep 32 sites of `tokio::time::sleep(200ms)` → explicit `recv_until(predicate)` waits. Add helper. |
| 4 | #670 (H22) | low | medium | Resolve `#670` (riverpod state-mutation propagation in widget tests). Unskip 6 optimistic-update tests. |
| 5 | #673 + #674-style sweep (H23/H24) | high | medium | Replace `waitForTimeout(5000-8000)` → `waitForSelector('flt-semantics')`. Replace pixel clicks with `getByRole`. Sweep all 58 occurrences. |
| 6 | #356 + #357 batch | high (devops) | medium | Pin Docker base images by digest, add root `.dockerignore`, add HEALTHCHECK to server image, add `mem_limit`/`cpus`/log rotation to compose, drop `e2e.yml continue-on-error`, fix Dockerfile migrations path, add SBOM + cosign keyless sign. Big batch but each item is small — do as one PR per concern. |
| 7 | #594 | low (sec) | small | GitHub tag ruleset restricting `v*` tags to github-actions[bot]. |

**Sprint 3 size**: ~10 days; H21 alone is ~3 days. Pull H19 forward if H21 spills.

**Exit criteria**:
- `cargo test --workspace` runs with per-test isolation; flake rate measured before/after
- `e2e.yml` returns real pass/fail (no more `continue-on-error: true`)
- Dependabot can bump pinned digests; one such PR exists and merges cleanly

---

## Sprint 4 — Architecture refactors + Riverpod modernization (weeks 7–8)

**Theme**: pay down the largest structural debt items the audit (and prior audits) keep flagging. This sprint is mostly Dart refactors, so it pairs naturally with the Riverpod question below.

| # | Issue | Severity | Effort | Notes |
|---|---|---|---|---|
| 1 | #512 + #628 | high (cq) | large | ChatPanel split. Move first-frame side effects out of `build`. Extract `ChatMessageList` widget. Pairs with Riverpod migration if approved. |
| 2 | #693 (H17) | high (cq) | large | `voice_lounge_screen.dart` split into `widgets/voice_lounge/`. |
| 3 | #513 | high (cq) | medium | `ChatInputBar` controller-driven feature modules. |
| 4 | #352 | high | medium | `ws/handler.rs` split: extract `voice_signal.rs`, `canvas_event.rs`, `broadcast_events.rs`. |
| 5 | #514 | medium | medium | Consolidate multipart upload paths behind one authenticated upload client. |
| 6 | #700 (H34) | high (cq) | medium | Wire-format constants single source in `core/rust-core/src/signal/protocol.rs`, re-exported to server. Phase 1 only — Dart parity test in a later sprint. |
| 7 | #702 (M40) | medium | medium-large | Migration consolidation: snapshot v2 baseline, archive historical, drop duplicate index. Coordinate with prod deploy window. |
| 8 | #701 | low (docs) | small | CLAUDE.md drift fixes (`is_deleted`, `api.rs`). One PR. |

**Sprint 4 size**: ~12 days of medium-to-large work. This sprint will likely **slip by 3-5 days**; that's OK because god-widget refactors are review-heavy and should not be rushed.

**Exit criteria**:
- ChatPanel and voice_lounge each have a `build` ≤80 lines
- `apps/server/src/ws/handler.rs` ≤400 lines
- Wire-format constants exist in exactly one place in Rust (Dart parity tracked separately)

---

## Items intentionally NOT in this 4-sprint plan

These are tracked but defer for now:

- **User-reported feature requests** (#449/#450/#451/#452/#454/#456 — rich text, threads, mentions, scheduled send, stickers): all `severity:high` user-reported but they are *features*, not debt. Slot one feature per sprint into the slack — likely **#451 (mentions)** in Sprint 1, **#449 (threads)** in Sprint 4 if Riverpod work doesn't fully consume.
- **Voice/UX refresh** (#210, #614, #613, #615): defer to a "polish" sprint after Sprint 4.
- **Encrypted groups full enforcement** (#591, #228, #658): blocked on Sprint 1 #686 + #687 landing first; pull into a Sprint 5.
- **Forgot password** (#476), **data export** (#398): both important but can wait until reliability is solid.
- **DevOps low-severity batch** (#358) and **UX polish backlogs** (#403/#404/#405): drip-feed via small PRs between sprint pulls.

## Risks & dependencies

- **Sprint 1 → Sprint 2** is hard-dependent: H14 (auth context) and H18 (DbErrCtx) need a stable route module first — Sprint 1 doesn't touch route shape.
- **Sprint 3 H21 (per-test isolation)** is the *biggest* schedule risk. If it slips, push H20/H19 into Sprint 4. Don't compromise H21 — it unblocks every future test reliability win.
- **Sprint 4 god-widget refactors** are the highest-conflict PRs (other branches touching same files). Plan a 2-day "no other PRs to chat_panel.dart" window per refactor.
- **Riverpod migration (see below)**: orthogonal to all four sprints; plug into Sprint 4 if the user opts in.

---

## Riverpod modernization (decision needed)

### Current state

- **Package**: `flutter_riverpod ^2.6.0` — already on Riverpod 2.x.
- **Style**: all 22 stateful providers use the legacy `StateNotifier` API (the original Riverpod 1.x pattern, kept around in 2.x for backwards compatibility but **soft-deprecated** in favor of `Notifier`/`AsyncNotifier`).
- **Codegen**: not in use. `build_runner` is already a dev dep, but neither `riverpod_generator` nor `riverpod_annotation` are pulled in.
- **Dart SDK**: `^3.11.4` (recent — supports all modern Riverpod 2.x and 3.x APIs).

> When the user asked about "switching to Riverpod" — the codebase is already there. The realistic interpretations are migrating *within* Riverpod.

### Three migration options

#### Option A — `StateNotifier` → `Notifier` / `AsyncNotifier` (modern Riverpod 2.x API)

- **Why**: The new `Notifier` API removes `StateNotifierProvider<MyNotifier, MyState>` boilerplate, supports `ref` directly inside the notifier (no constructor injection), composes better with `AsyncNotifier` for async state, and is the path Riverpod is steering toward. `StateNotifier` is functional but increasingly second-class.
- **Audit synergy**: H16 (#512), H17 (#693), and #628 (god-widget refactor) all extract smaller widgets/controllers. The new pieces are a natural place to drop the new API. Co-locating the refactor + API migration avoids touching the same files twice.
- **Workload**: 22 providers ranging from ~50 LoC (`server_url_provider`, `theme_provider`) to ~600 LoC (`chat_provider`). Estimate **~12-15 working days** for one engineer (4 days for the simple ones, 7-9 for the complex ones — `chat_provider`, `crypto_provider`, `livekit_voice_provider`, `ws_message_handler` — plus call-site sweep). Tests need updating; can migrate one provider at a time and ship incrementally on `dev`.
- **Risk**: low. Existing tests guard behavior. New API can coexist with old during the migration.

#### Option B — Add `@riverpod` codegen on top

- **Why**: Eliminates manual `Provider<...>` declarations. Provider name + type derived from method/class. Reduces the `final myProvider = Provider<MyType>((ref) => ...)` boilerplate by ~70% per provider. Pairs naturally with Option A — many teams do A and B together.
- **Workload**: an additional **~3-5 days** on top of Option A (mechanical: add annotations, run `build_runner`, update imports). Adds `riverpod_generator`, `riverpod_annotation`, `custom_lint`, `riverpod_lint` dev deps.
- **Risk**: low–medium. Codegen adds a build step (`flutter pub run build_runner build`); CI needs to handle `.g.dart` file freshness. Adds ~1-2s to incremental builds.

#### Option C — Bump to Riverpod 3.x (`flutter_riverpod ^3.0.0`)

- **Why**: 3.x is the current major. Some breaking changes from 2.x (mostly removing already-deprecated APIs and tightening types). Future-proofing.
- **Workload**: **~2-3 days** for the bump itself. Most breaking changes are minor; `StateNotifier` paths still work in 3.x but the `legacy_provider` path is being phased out. Best done **before** Option A so you're targeting the modern API directly.
- **Risk**: medium. Behavioral edge cases around `ref.invalidate` and `keepAlive` semantics changed slightly. Need a soak window.

### Recommendation

**Do A + B together, in Sprint 4, after the god-widget refactors land** (or interleaved with them). Skip C for now unless you hit a 3.x-only feature you need; `StateNotifier` legacy support in 3.x is unlikely to be removed before 4.x.

Concretely for Sprint 4:
- After splitting ChatPanel (#512), migrate `chat_provider` to `AsyncNotifier` *as part of the split PR*, since the consumer surface is changing anyway.
- Same pattern for voice_lounge (#693) → `livekit_voice_provider`, `voice_rtc_provider`, `voice_settings_provider`, `screen_share_provider`.
- Leftover providers (auth, theme, contacts, etc.) become a Sprint 5 sweep.

Total **incremental workload over Sprint 4**: roughly **+5 days** if interleaved with the refactors (the base refactor work was already there; the API change is mostly mechanical), or **+12-18 days** as a separate dedicated sprint.

### Why not "swap state management entirely"

The audit doesn't flag any state-management *concept* problems — the issues are:
- Provider granularity (#578: `ref.watch` whole map instead of `select`)
- Side effects in `build` (H16 / #512)
- God orchestrators (#693, ws_message_handler.dart 901 lines)
- Set rebuilds (#676)

None of these are solved by switching to Bloc, signals, or any other library — they're discipline issues that hurt under any state-mgmt system. Riverpod is a fine choice; the modernization is about API ergonomics, not correctness.
