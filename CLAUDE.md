# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Echo Messenger -- encrypted cross-platform chat app (Discord alternative). Rust server + Flutter client (web, Linux, Windows, Android, iOS). Live at https://echo-messenger.us. Self-hosted via Docker + Traefik.

## Git Workflow

**Always work on the `dev` branch (or a `feature/**` / `fix/**` branch).** Push, then merge to `main` via PR.

- `dev` / `feature/**` / `fix/**` branches: runs lint CI (Rust CI + Flutter CI) + path-gated dev builds. Only the platforms whose files actually changed get a build artifact — push Android-only changes and only the unsigned debug APK builds; push shared Dart and every client platform builds. iOS is cost-gated (see CI section). See the filter map under `## CI` below for which paths trigger which platform.
- `main` branch: runs the full release pipeline (Linux, Windows, Android, iOS, Web, Server, Docker, GitHub Release) — every platform builds on every release. Auto-increments patch version from git tags.
- **Never push directly to `main`** unless it's a hotfix. Use `git checkout dev && git merge main` to sync.

```bash
git checkout dev                    # Or feature/foo / fix/bar
git push origin dev                 # Triggers lint + path-gated dev builds
gh pr create --base main            # When ready for release
```

## Prerequisites

Rust (edition 2024), Flutter 3.41+ (SDK `^3.11.4`), Docker (for PostgreSQL), Node.js 20+ (for commitlint + Playwright).

## Build & Run

```bash
# All-in-one local dev (starts PostgreSQL + server + creates test user)
./scripts/run.sh

# Or manually:
cd infra/docker && docker compose up -d          # PostgreSQL 17 on :5432
cargo run -p echo-server                          # Server on :8080
cd apps/client && flutter pub get && flutter run -d linux

# Web build (CanvasKit required for visual parity with desktop)
flutter build web --release --pwa-strategy=none --dart-define=APP_VERSION=X.Y.Z
```

**run.sh** accepts optional `[username] [password]` args. Default is `dev/devpass123`, which also auto-creates demo contacts (alice, bob, charlie).

**Other scripts**: `scripts/demo_two_apps.sh` (launch two client instances for testing), `scripts/seed_demo_data.sh` (populate test data).

## Tests

```bash
cargo test --workspace                            # Rust: 250+ tests (Signal Protocol + server integration)
cargo test -p echo-server -- test_name            # Run a single Rust test
cd apps/client && flutter test                    # Flutter: 764+ tests (crypto, models, state, widgets)
cd apps/client && flutter test test/path_test.dart # Run a single Flutter test file
./scripts/test_e2e.sh                             # E2E integration tests
npx playwright test                               # Visual tests (Playwright, tests/e2e/)
npx playwright test tests/e2e/some.spec.ts        # Run a single Playwright spec
```

## Lint & Format

```bash
cargo fmt --all -- --check                        # Rust format
cargo clippy --workspace --all-targets            # Rust lint
cd apps/client && dart format --set-exit-if-changed .   # Dart format
cd apps/client && flutter analyze --fatal-infos   # Dart lint
```

Pre-commit hooks (lefthook, run in parallel): cargo fmt check + clippy `-D warnings` on .rs files, dart format + flutter analyze on .dart files, commitlint on commit messages. Conventional commits enforced.

**Security CI** (runs on push): cargo audit (RUSTSEC-2023-0071 ignored -- jsonwebtoken timing sidechannel, no patch), cargo-deny (license + ban checks), trufflehog (secret detection). The release workflow's `security-pre-release` gate is path-gated on Rust dep files (see `## CI` below); the nightly `security-nightly.yml` at 06:00 UTC catches advisory-database drift even on days with no Rust changes.

**CI secrets**: `CODECOV_TOKEN` (recommended) lets the Flutter CI codecov upload authenticate; without it the action falls back to OIDC. `ANDROID_KEYSTORE_BASE64` + `ANDROID_KEY_PROPERTIES` are required by the release workflow's Android job and fail-fast if missing.

## CI

**Caching** is applied across every workflow: cargo registry + `target/` via `Swatinem/rust-cache`, `~/.pub-cache` + `apps/client/.dart_tool` keyed on `pubspec.lock`, Gradle caches keyed on `apps/client/android/**/*.gradle*`, CocoaPods (`apps/client/ios/Pods`, `apps/client/macos/Pods`, `~/.cocoapods`) keyed on `pubspec.lock`, and the Linux AppImage tool downloads. Cold runs prime the caches; warm runs typically drop 5-10 min off Rust-heavy jobs.

**Path-gated dev builds** (`dev-build.yml`): runs on push to `dev`, `feature/**`, `fix/**`. A `paths` job using `dorny/paths-filter@v3` declares one filter per platform. Each `build-*` job only runs if its filter matches OR `dev-build-workflow` matches (= workflow file changed → rebuild everything). The filter map:

| Filter | Triggers on changes to |
|--------|------------------------|
| `linux` | Dart sources + `apps/client/linux/**` |
| `windows` | Dart sources + `apps/client/windows/**` |
| `android` | Dart sources + `apps/client/android/**` |
| `ios` | Dart sources + `apps/client/ios/**` |
| `macos` | Dart sources + `apps/client/macos/**` |
| `web` | Dart sources + `apps/client/web/**` + `Dockerfile.web` |
| `server` | `apps/server/**`, `core/rust-core/**`, `Cargo.{toml,lock}` |
| `dev-build-workflow` | `.github/workflows/dev-build.yml` (force-rebuild all) |

"Dart sources" = `apps/client/{pubspec.yaml,pubspec.lock,lib/**,test/**}` + `.flutter-version`.

**iOS cost gate**: macOS-15 runners cost ~10x Linux. `build-ios` only runs when its path filter is true AND the trigger is `workflow_dispatch` OR the commit message contains the literal `[ci-ios]` marker. `build-macos` stays `workflow_dispatch`-only. Android and Windows have no cost gate (Linux runner + 2x Windows respectively).

**Main releases unchanged**: `release.yml` still builds every platform on every push to `main`. The two new pieces are (1) `security-pre-release` is gated on Rust dep paths (`Cargo.lock`, `Cargo.toml`, `**/Cargo.toml`, `deny.toml`) ∨ workflow-file changes -- audit on every commit is wasteful when deps haven't moved -- and (2) the old monolithic `lint-test` job is split into `lint-test-rust` (gated on `server` filter) and `lint-test-flutter` (gated on any client filter). Each `build-*` job's `needs:` references only the relevant lint job. The `version` job and every `build-*` accept `success || skipped` on their lint dependency so a Rust-only release still runs every Flutter build and vice versa.

**Nightly security drift** (`security-nightly.yml`): runs `cargo audit` + `cargo deny check` at 06:00 UTC daily. Catches RustSec advisories published against an unchanged lockfile within 24h. Failure opens (or updates) a Security-labelled GitHub issue via `peter-evans/create-issue-from-file`.

**Triggering an iOS dev build**: either `gh workflow run dev-build.yml --ref feature/my-branch` or append `[ci-ios]` to the latest commit message on the branch.

## Architecture

**Workspace** (Cargo workspace at root):
- `apps/server/` -- Rust Axum HTTP + WebSocket server, PostgreSQL via SQLx
- `apps/client/` -- Flutter app, Riverpod state management, GoRouter navigation
- `core/rust-core/` -- Shared Rust library: Signal Protocol (X3DH + Double Ratchet), crypto primitives, FFI bridge

**Server startup sequence** (main.rs): load .env -> tracing -> create upload dirs (`./uploads/avatars`) -> Config::from_env() -> PG pool + auto-migrate SQL files (`apps/server/migrations/`, 14 migrations) -> spawn WebSocket Hub (DashMap) -> spawn background tasks (stale voice session cleanup every 60s, empty group cleanup) -> build Axum router -> bind with graceful shutdown.

**Key server modules**:
- `auth/` -- JWT (15-min access + 7-day refresh), Argon2id passwords, AuthUser middleware extractor
- `ws/hub.rs` -- DashMap<user_id, mpsc::Sender> for lock-free WS routing
- `ws/handler.rs` -- WS upgrade, message parsing, event dispatch (MessageRelayed, TypingIndicator, Reaction, Online/Offline)
- `db/` -- query modules (users, messages, contacts, groups, keys, reactions, media, tokens, devices, push_tokens)
- `routes/` -- REST: /api/auth, /api/users, /api/contacts, /api/messages, /api/groups, /api/keys, /api/reactions, /api/media, /api/channels, /api/voice, /api/group_keys, /api/link_preview

**Client init** (main.dart): Hive local DB -> message cache -> load persisted server URL (web: overridable via `?server=` query param) -> load sound prefs -> request notification permission -> SplashScreen handles auto-login + crypto init.

**Client local storage**: Hive for offline message cache and app state; flutter_secure_storage for private keys (platform keystore); SharedPreferences for settings.

**Client state** (Riverpod StateNotifiers with immutable copyWith):
- `auth_provider` -- login/register/logout/auto-login, persists to SharedPreferences
- `crypto_provider` -- Signal Protocol init, encrypt/decrypt messages
- `websocket_provider` -- WS lifecycle, auto-reconnect with exponential backoff
- `chat_provider` -- conversations + messages, calls crypto_provider for E2E
- `conversations_provider` -- conversation list, unread counts, typing indicators

**Signal Protocol crypto**:
- Rust reference: `core/rust-core/src/signal/`
- Dart production: `apps/client/lib/src/services/signal_protocol.dart`, `signal_x3dh.dart`, `signal_session.dart`
- 1:1 messages: X3DH key exchange + Double Ratchet (end-to-end encrypted)
- Group messages: group key envelopes infrastructure exists (`group_crypto_service.dart`, `routes/group_keys.rs`) but not fully wired. When `is_encrypted=true` is enabled on a group, `sendGroupMessage` hard-fails on encryption errors instead of falling back to plaintext (#344) — server-side ciphertext-only enforcement is tracked separately (#591). **The full design proposal for extending this into a real group E2E protocol (GRP2 = Sender Keys + server-led leader election + per-message sender signatures) lives in [docs/group-e2e-design/](docs/group-e2e-design/). Open product questions are in [docs/group-e2e-design/06-open-questions.md](docs/group-e2e-design/06-open-questions.md).**
- `@everyone` / `@here` broadcast mentions are surfaced in the group mention autocomplete picker (#451). `@here` causes the server to skip APNs push to offline members (plaintext groups only; encrypted groups are unaffected because the literal text never appears in ciphertext).

**Voice & Video** (LiveKit integration):
- Server: `routes/voice.rs` handles call signaling and LiveKit token generation
- Client: `livekit_voice_provider.dart`, `voice_rtc_provider.dart`, `voice_settings_provider.dart`
- Requires `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` env vars in production

## Code-quality budgets

These are the rules SonarCloud enforces. Treat them as hard limits, not suggestions — closing batch findings later is far more expensive than writing within budget the first time.

- **Cognitive complexity ≤ 15 per function (S3776).** If you're writing a method that nests three levels of `if`/`switch`/`for` or branches more than ~8 times, split it. Extract the inner branches into named helpers (`_resolveX`, `_buildY`, `_handleZ`) so the outer method reads as an orchestration. Don't ship `someBigMethod()` of 80+ lines just because "it's all related" — the reader can't hold that much.
- **Function parameters ≤ 7 (S107).** Past 7 params, signatures stop being self-documenting and call sites become a maze of positional/named arguments. Group related params into a small data class (`class XParams { final ...; const XParams({required ...}); }`) before adding the 8th. Exceptions are `copyWith`-style methods on immutable state — those are wide on purpose. Document the exception in a `// S107:` comment so the next reader knows it was deliberate.
- **No nested ternaries (S3358).** `a ? b : c ? d : e` is unreadable. Pull the inner ternary into a local variable or helper getter (`_resolveColor()`).
- **No duplicate string literals (S1192).** Three+ uses of the same literal becomes a `const String _kFoo = '...'` at file scope.
- **No `final` for compile-time constants (S3962).** Use `const` when the value is fully literal.

### Componentize when you'd otherwise paste twice

If you find yourself copy-pasting a widget tree (an avatar + presence dot, a confirm dialog, a bottom-sheet shell, etc.) into a second file, **stop and componentize it instead**. The goal is "change one thing somewhere, every callsite changes" — not "15 hand-rolled copies drift apart over six months." Search the codebase before writing a new widget tree:

- Avatars + presence dot → `UserAvatar` in `widgets/user_avatar.dart`.
- Confirm dialogs → `showEchoConfirmDialog` in `widgets/confirm_dialog.dart`.
- Bottom sheets → `showEchoBottomSheet` in `widgets/echo_bottom_sheet.dart`.
- Member role icon/pill → `MemberRoleIcon` / `MemberRoleBadge` in `widgets/member_role.dart`.
- Presence colour / label → `presenceColor` / `presenceLabel` in `utils/presence.dart`.
- Per-user presence lookup → `userPresenceProvider(userId)`.
- Copy text + toast → `copyToClipboard(context, text, successMessage: ...)`.
- Empty state with illustration → `EmptyState` in `widgets/empty_state.dart`.

If your use case doesn't fit an existing helper, **extend the helper rather than fork it**. New options or `destructive: true`-style flags belong in the shared widget so the next user picks them up automatically.

## Critical Conventions

- **WebSocket auth**: ticket-based only (`?ticket=`, NOT `?token=`). Client calls POST /api/auth/ws-ticket for 30-sec single-use ticket. JWT never in WS URL.
- **Web renderer**: CanvasKit is the default (and only) renderer in Flutter 3.22+. The `--web-renderer` flag was removed.
- **Rust edition 2024** used in both Cargo.toml and rustfmt.toml.
- **rustfmt**: max_width=100, Unix newlines, field_init_shorthand + try_shorthand enabled.
- **Server required env**: `DATABASE_URL` and `JWT_SECRET` (≥32 chars, panics without them). Optional: `SERVER_HOST` (default `0.0.0.0`), `SERVER_PORT` (default `8080`), `CORS_ORIGINS` for allowed origins, `RUST_LOG` for log filtering (e.g. `echo_server=debug`). Legacy `HOST`/`PORT` are still accepted but emit a deprecation warning at startup (#532).
- **Traefik routing**: API priority 100, Web priority 1 (API routes must take precedence). Phase 1 of the domain migration (#1063) means both the apex and `us-east.echo-messenger.us` (API) / `web.echo-messenger.us` (web) hit the same routers via a Host union — see [docs/domain-migration/](docs/domain-migration/) for the phased plan, including the cookie/CORS work Phase 2 needs.
- **Message wire format**: Initial V2 (with OTP) = `[0xEC, 0x02] + identity_pub(32) + ephemeral_pub(32) + otp_id(4 LE) + ratchet_wire`; Initial V1 (no OTP) = `[0xEC, 0x01] + identity_pub(32) + ephemeral_pub(32) + ratchet_wire`; Normal = `header_len(4 LE) + header(40) + nonce(12) + ciphertext + tag(16)`. All base64-wrapped over WebSocket.
- **Soft deletes**: Messages use a `deleted_at TIMESTAMPTZ NULL` column; queries filter with `deleted_at IS NULL`. Hard deletes only happen during `cleanup_expired_messages` (disappearing TTL) and `delete_group_dependents`.
- **Refresh tokens (web)**: HttpOnly + Secure + SameSite=Strict cookie scoped to `/api/auth`; mobile/desktop continue to use the JSON body. `/refresh` accepts either; cookie wins. CORS requires explicit origins (not `*`) when cookie auth is enabled.

## Commit Style

Conventional commits, short and human-readable. One line subject, optional brief body. Examples from this repo:
- `fix: Signal Protocol session establishment -- Alice/Bob role detection`
- `feat: Signal Protocol integration -- X3DH + Double Ratchet in Dart + device-aware server`
- `refactor: upgrade theme to ThemeExtension for scalable custom themes`

Keep it concise -- no multi-paragraph explanations, no bullet lists in commit messages. No co-author tags.

Allowed types: `feat fix docs style refactor perf test build ci chore revert security`. Optional scopes: `core server client infra proto crypto ci deps`. Subject must be lowercase, max 80 chars (commitlint hard cap; aim for 72 to leave headroom for the `(#N)` suffix).

### Release-quality subjects (commit messages AND PR titles)

The "What's New" modal on the next app update renders the GitHub release notes verbatim. Release notes are auto-generated from merged PR titles and their commit subjects. So every PR title and every commit subject is one row of the changelog that the user sees on first launch after the update.

Optimize for the reader who is NOT a contributor:

- **Lead with the user-visible behavior**, not the implementation mechanism.
  - Bad: `refactor(client): consolidate hardcoded ui colors into 4 new theme tokens`
  - Good: `style(client): unify component colors across themes`
  - Bad: `fix(server): revalidate invite token inside consume tx to prevent toctou over-use`
  - Good: `fix(server): close invite-link race that let groups exceed max-uses`
  - Bad: `perf(server): hoist heartbeat payload const + abort ping on disconnect`
  - Good: `perf(server): trim per-WS heartbeat allocation and stale-task overhead`

- **Drop the internal vocabulary** users don't have:
  - Avoid: `toctou`, `codegen`, `cte`, `riverpod`, `provider`, `mixin`, `hook`, `dart format`, `clippy`, `lefthook`, `valuenotifier`, `widget tree`, `ledger`, `fanout`, `dedupe`.
  - When the mechanism is unavoidable (e.g. you literally split a file), say so plainly: `refactor(client): split chat panel into smaller widgets`.

- **PR titles especially** become the headline of the release-notes section for that change. Treat the PR title as marketing copy, not a code summary:
  - Internal: `fix(server): backend audit batch — multi-device delivery, invite toctou, mention fanout (#829)`
  - Release-quality: `Fix message delivery to offline phones and tighten group-invite limits (#829)`

- **Skip the changelog for noise**: `chore(deps)`, `ci(...)`, `build(...)`, `docs(...)` commits do not need user-facing language — they're naturally filtered out of the modal by `sanitizeReleaseBody` in `apps/client/lib/src/providers/update_provider.dart` (Dependabot bump URLs, `Co-Authored-By`, the auto-generated Full Changelog trailer all get stripped). Write these for fellow contributors.

- **Group the impact in PR bodies**. When a PR bundles several slices, the PR body becomes the body of the release-notes section. Lead with a 1-2 sentence summary that describes what the user gets, then list bullets grouped as `New`, `Improved`, `Fixed`, `Behind the scenes`. The "Behind the scenes" group is where refactors / test additions / build changes go — they can stay technical because the section header pre-frames them.

- **Reference issues** with `(#N)` so the modal links back, but don't lead the subject with the issue number.

When in doubt: read the subject aloud as if you were narrating an app update to a non-technical friend. If it sounds like API docs, rewrite.

## Project Commands

Slash commands scoped to this project (`.claude/commands/`):
- `/echo-dev <task>` -- Full development workflow with all project standards
- `/echo-fix <bug>` -- Bug fix with mandatory reproduction test before the fix
- `/echo-feat <feature>` -- Feature implementation with tests, a11y, and pipeline compliance

These enforce: test-first for bugs, test-after for features, conventional commits (no co-author), semantic labels on interactive widgets, theme-aware colors, and pipeline formatting rules.

**When to use**: Any code change should follow `/echo-dev` rules. Use `/echo-fix` for bugs (writes reproduction test first) and `/echo-feat` for features (writes tests after). During `/next-task` or any implementation workflow, follow the standards in `/echo-dev` automatically — do not wait for explicit invocation.

## Docker Production

Server image: multi-stage Rust build -> `debian:bookworm-slim`, non-root user (`echo:echo`, UID 1000), `tini` for signal handling. Web image: `nginx:alpine` serving Flutter web build. Both versioned via build args (`BUILD_ID`, `APP_VERSION`).

Three compose files in `infra/docker/`:
- `docker-compose.yml` -- local dev (PostgreSQL 17 on port 5432)
- `docker-compose.test.yml` -- CI (PostgreSQL on port 5433, avoids conflicts)
- `docker-compose.prod.yml` -- production: Traefik with Cloudflare TLS, PostgreSQL backups (7-day/4-week/6-month retention), LiveKit for voice

**Prod deploy** runs on the host via `containrrr/watchtower` watching `:latest`-tagged images. The repo's release pipeline publishes new images to GHCR; watchtower picks them up on its next interval and recreates the affected containers. Note that the host's running compose (`~/docker-server/echo-messenger/docker-compose.yml`) sets `WEB_VERSION=latest` / `SERVER_VERSION=latest` and is not the same file as the repo's `infra/docker/docker-compose.prod.yml` (which pins explicit versions and is the documented manual fallback). The host compose also overrides the web service `healthcheck` to use `curl http://127.0.0.1/` -- the image's baked-in `wget http://localhost/healthz` resolves to IPv6 first, which nginx doesn't listen on, so the container shows unhealthy and Traefik's docker provider silently filters it out (#prod-2026-05-08).

**Prod smoke** is `.github/workflows/prod-smoke.yml` -- a manual-dispatch workflow that runs the Playwright manual specs against the live URL from a GitHub-hosted runner (no SSH, no host access). Useful as a post-deploy sanity check.

## Known Limitations

1. Session keys cached in memory with 24h idle TTL + 200-entry LRU cap; evicted entries have key material zeroed and reload from secure storage on demand.
2. Multi-device: key-level revoke + last_seen + platform metadata work end-to-end; refresh tokens are not yet bound per device, so "logout all others" only kicks connected sessions via WS and truly offline sessions get blocked at next key operation.
3. `core/rust-core` ships Signal Protocol primitives only (X3DH, Double Ratchet, key types). The originally-planned FFI bridge to a Dart-side runtime never landed; the Dart client re-implements the protocol in pure Dart and the rust-core code path is exercised only by Rust integration tests. The abandoned FFI deps (`rusqlite`, `tokio-tungstenite`, `reqwest`, `tokio`, `futures-util`) have been pruned from `core/rust-core/Cargo.toml` — the file now carries only what the Signal primitives + benches use, and an explanatory comment documents why those deps are deliberately absent. **The dual-implementation question (keep both vs delete the Rust port vs FFI bridge) is analysed in [docs/crypto-audit/05-rust-core-vs-dart.md](docs/crypto-audit/05-rust-core-vs-dart.md)**; current recommendation is to keep both and add a cross-implementation wire-compat test (audit P2-2) before re-deciding.
4. Rate limiting is in-memory only (resets on server restart)
