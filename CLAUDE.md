# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Echo Messenger -- encrypted cross-platform chat app (Discord alternative). Rust server + Flutter client (web, Linux, Windows). Live at https://echo-messenger.us. Self-hosted via Docker + Traefik + Watchtower.

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

## Tests

```bash
cargo test --workspace                            # Rust: 53 tests (Signal Protocol + server)
cd apps/client && flutter test                    # Flutter: 51 tests (crypto, models, state)
./scripts/test_e2e.sh                             # E2E integration tests
npx playwright test                               # Visual tests
```

## Lint & Format

```bash
cargo fmt --all -- --check                        # Rust format
cargo clippy --workspace --all-targets            # Rust lint
cd apps/client && dart format --set-exit-if-changed .   # Dart format
cd apps/client && flutter analyze --fatal-infos   # Dart lint
```

Pre-commit hooks (lefthook): cargo fmt check + clippy on .rs files, commitlint on commit messages. Conventional commits enforced.

## Architecture

**Workspace** (Cargo workspace at root):
- `apps/server/` -- Rust Axum HTTP + WebSocket server, PostgreSQL via SQLx
- `apps/client/` -- Flutter app, Riverpod state management, GoRouter navigation
- `core/rust-core/` -- Shared Rust library: Signal Protocol (X3DH + Double Ratchet), crypto primitives, FFI bridge

**Server startup sequence** (main.rs): load .env -> tracing -> Config::from_env() -> PG pool + auto-migrate 13 SQL files -> spawn WebSocket Hub (DashMap) -> build Axum router -> bind.

**Key server modules**:
- `auth/` -- JWT (15-min access + 7-day refresh), Argon2id passwords, AuthUser middleware extractor
- `ws/hub.rs` -- DashMap<user_id, mpsc::Sender> for lock-free WS routing
- `ws/handler.rs` -- WS upgrade, message parsing, event dispatch (MessageRelayed, TypingIndicator, Reaction, Online/Offline)
- `db/` -- 9 query modules (users, messages, contacts, groups, keys, reactions, media, tokens)
- `routes/` -- REST: /api/auth, /api/users, /api/contacts, /api/messages, /api/groups, /api/keys, /api/reactions, /api/media

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
- Group messages: currently unencrypted (server relays plaintext)

## Critical Conventions

- **WebSocket auth**: ticket-based only (`?ticket=`, NOT `?token=`). Client calls POST /api/auth/ws-ticket for 30-sec single-use ticket. JWT never in WS URL.
- **Web renderer**: CanvasKit is the default (and only) renderer in Flutter 3.22+. The `--web-renderer` flag was removed.
- **Rust edition 2024** used in both Cargo.toml and rustfmt.toml.
- **rustfmt**: max_width=100, Unix newlines, field_init_shorthand + try_shorthand enabled.
- **Server required env**: `DATABASE_URL` and `JWT_SECRET` (panics without them). `CORS_ORIGINS` for allowed origins.
- **Traefik routing**: API priority 100, Web priority 1 (API routes must take precedence).
- **Message wire format**: Initial = `[0xEC, 0x01] + identity_pub(32) + ephemeral_pub(32) + session_wire`; Normal = `header_len(4 LE) + header(40) + nonce(12) + ciphertext + tag(16)`. Both base64-wrapped over WebSocket.
- **Soft deletes**: Messages use `is_deleted` flag, not hard deletes.

## Known Limitations

1. Private keys stored in SharedPreferences (should use flutter_secure_storage / platform keystore)
2. Session keys cached forever in memory (no TTL)
3. Multi-device: schema exists but single-device in practice
4. `core/rust-core/src/api.rs` has `todo!()` stubs (FFI bridge not integrated)
5. Rate limiting is in-memory only (resets on server restart)
