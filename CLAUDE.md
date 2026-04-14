# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Echo Messenger -- encrypted cross-platform chat app (Discord alternative). Rust server + Flutter client (web, Linux, Windows, Android, iOS). Live at https://echo-messenger.us. Self-hosted via Docker + Traefik.

## Git Workflow

**Always work on the `dev` branch.** Push to `dev`, then merge to `main` via PR.

- `dev` branch: runs lint CI (Rust CI + Flutter CI) + dev builds (Linux AppImage + Web only)
- `main` branch: runs the full release pipeline (Linux, Windows, Android, iOS, Web, Server, Docker, GitHub Release). Auto-increments patch version from git tags.
- **Never push directly to `main`** unless it's a hotfix. Use `git checkout dev && git merge main` to sync.

```bash
git checkout dev                    # Work here
git push origin dev                 # Triggers lint + dev builds only
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
cargo test --workspace                            # Rust: 241 tests (Signal Protocol + server integration)
cargo test -p echo-server -- test_name            # Run a single Rust test
cd apps/client && flutter test                    # Flutter: 55 tests (crypto, models, state)
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

**Security CI** (runs on push): cargo audit (RUSTSEC-2023-0071 ignored -- jsonwebtoken timing sidechannel, no patch), cargo-deny (license + ban checks), trufflehog (secret detection).

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
- Group messages: group key envelopes infrastructure exists (`group_crypto_service.dart`, `routes/group_keys.rs`) but not fully wired

**Voice & Video** (LiveKit integration):
- Server: `routes/voice.rs` handles call signaling and LiveKit token generation
- Client: `livekit_voice_provider.dart`, `voice_rtc_provider.dart`, `voice_settings_provider.dart`
- Requires `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` env vars in production

## Critical Conventions

- **WebSocket auth**: ticket-based only (`?ticket=`, NOT `?token=`). Client calls POST /api/auth/ws-ticket for 30-sec single-use ticket. JWT never in WS URL.
- **Web renderer**: CanvasKit is the default (and only) renderer in Flutter 3.22+. The `--web-renderer` flag was removed.
- **Rust edition 2024** used in both Cargo.toml and rustfmt.toml.
- **rustfmt**: max_width=100, Unix newlines, field_init_shorthand + try_shorthand enabled.
- **Server required env**: `DATABASE_URL` and `JWT_SECRET` (≥32 chars, panics without them). Optional: `HOST` (default `0.0.0.0`), `PORT` (default `8080`), `CORS_ORIGINS` for allowed origins, `RUST_LOG` for log filtering (e.g. `echo_server=debug`).
- **Traefik routing**: API priority 100, Web priority 1 (API routes must take precedence).
- **Message wire format**: Initial V2 (with OTP) = `[0xEC, 0x02] + identity_pub(32) + ephemeral_pub(32) + otp_id(4 LE) + ratchet_wire`; Initial V1 (no OTP) = `[0xEC, 0x01] + identity_pub(32) + ephemeral_pub(32) + ratchet_wire`; Normal = `header_len(4 LE) + header(40) + nonce(12) + ciphertext + tag(16)`. All base64-wrapped over WebSocket.
- **Soft deletes**: Messages use `is_deleted` flag, not hard deletes.

## Commit Style

Conventional commits, short and human-readable. One line subject, optional brief body. Examples from this repo:
- `fix: Signal Protocol session establishment -- Alice/Bob role detection`
- `feat: Signal Protocol integration -- X3DH + Double Ratchet in Dart + device-aware server`
- `refactor: upgrade theme to ThemeExtension for scalable custom themes`

Keep it concise -- no multi-paragraph explanations, no bullet lists in commit messages. No co-author tags.

Allowed types: `feat fix docs style refactor perf test build ci chore revert security`. Optional scopes: `core server client infra proto crypto ci deps`. Subject must be lowercase, max 72 chars.

## Docker Production

Server image: multi-stage Rust build -> `debian:bookworm-slim`, non-root user (`echo:echo`, UID 1000), `tini` for signal handling. Web image: `nginx:alpine` serving Flutter web build. Both versioned via build args (`BUILD_ID`, `APP_VERSION`).

Three compose files in `infra/docker/`:
- `docker-compose.yml` -- local dev (PostgreSQL 17 on port 5432)
- `docker-compose.test.yml` -- CI (PostgreSQL on port 5433, avoids conflicts)
- `docker-compose.prod.yml` -- production: Traefik with Cloudflare TLS, PostgreSQL backups (7-day/4-week/6-month retention), LiveKit for voice

## Known Limitations

1. Session keys cached forever in memory (no TTL)
2. Multi-device: schema exists but single-device in practice
3. `core/rust-core/src/api.rs` has `todo!()` stubs (FFI bridge not integrated)
4. Rate limiting is in-memory only (resets on server restart)
