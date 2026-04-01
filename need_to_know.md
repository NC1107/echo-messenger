# Need To Know -- Echo Messenger Project

Last updated: 2026-04-01

## Project Overview
Decentralized encrypted chat app. Rust server + Flutter client (web, Linux, Windows). Live at https://echo-messenger.us. Self-hosted on home server with Traefik reverse proxy + Watchtower auto-deploy.

## Architecture
- **Server**: Rust (Axum) at `apps/server/`, PostgreSQL, WebSocket for real-time
- **Client**: Flutter at `apps/client/`, single codebase for web + desktop
- **Crypto core**: Rust Signal Protocol at `core/rust-core/src/signal/`, Dart port at `apps/client/lib/src/services/signal_*.dart`
- **Docker**: Server + Web (nginx) containers, `infra/docker/docker-compose.prod.yml`
- **CI**: GitHub Actions, auto-versioned releases on push to main

## Critical Knowledge

### Web Build
```bash
flutter build web --release --pwa-strategy=none --dart-define=APP_VERSION=$VERSION
```
- CanvasKit is the default (and only) web renderer in Flutter 3.22+. The `--web-renderer` flag was removed.
- `--pwa-strategy=none` -- Disables service worker to prevent stale JS caching
- `--dart-define=APP_VERSION=X.Y.Z` -- Injects version at compile time

### Versioned Web Deployment (recommended by server admin)
Instead of serving from root, deploy each version to a unique path:
```bash
export RELEASE="0.0.X"
rm -rf ./build/web
flutter build web --release --base-href /$RELEASE/ --pwa-strategy=none
mkdir -p build/web_output/$RELEASE
mv build/web/* build/web_output/$RELEASE
mv build/web_output/$RELEASE/index.html build/web_output/index.html
cp build/web_output/$RELEASE/version.json build/web_output/version.json
```
This eliminates ALL caching issues since each version has a unique URL.

### Signal Protocol Encryption
- **Rust reference**: `core/rust-core/src/signal/` (41 tests)
- **Dart production**: `apps/client/lib/src/services/signal_protocol.dart`, `signal_x3dh.dart`, `signal_session.dart`
- **X3DH**: Extended Triple DH for initial key exchange. Alice initiates, Bob responds.
- **Double Ratchet**: Per-message forward secrecy with chain ratcheting
- **Initial message format**: `[0xEC, 0x01] + alice_identity_pub(32) + alice_ephemeral_pub(32) + session_wire`
- **Normal message format**: `header_len(4 LE) + header(40) + nonce(12) + ciphertext + tag(16)`
- **Both wrapped in base64** before sending over WebSocket
- **Key reset**: Settings > Privacy > Reset Encryption Keys (both users must reset for new sessions)

### WebSocket Authentication
- Server ONLY accepts `?ticket=` (not `?token=`)
- Client calls `POST /api/auth/ws-ticket` to get 30-second single-use ticket
- JWT never appears in WebSocket URL (security requirement)

### Token Architecture
- Access token: 15 minutes
- Refresh token: 7 days, stored hashed in DB, rotatable
- Client auto-refreshes on 401 responses via `authenticatedRequest()` wrapper
- No plaintext passwords stored (removed)

### Theme System
- Uses Flutter `ThemeExtension<EchoColorExtension>` for scalable themes
- All widgets use `context.mainBg`, `context.surface`, `context.textPrimary` etc.
- Adding new theme = define new `EchoColorExtension` + `ThemeData`
- Light + Dark themes defined, switchable in Settings > Appearance

### Docker/Deployment
- Server: `ghcr.io/nc1107/echo-messenger/server:latest`
- Web: `ghcr.io/nc1107/echo-messenger/web:latest`
- Traefik labels: API priority 100, Web priority 1 (API routes MUST take precedence)
- `CORS_ORIGINS` env var controls allowed origins (default: echo-messenger.us + localhost:8081)
- `JWT_SECRET` MUST be set (server panics without it)
- `DATABASE_URL` MUST be set (server panics without it)
- Watchtower polls every 5 minutes for new images

### Key Environment Variables (Server)
- `DATABASE_URL` -- PostgreSQL connection string (REQUIRED)
- `JWT_SECRET` -- JWT signing secret, 32+ bytes (REQUIRED)
- `RUST_LOG` -- Log level (default: echo_server=info)
- `CORS_ORIGINS` -- Comma-separated allowed origins, or `*` for dev
- `SERVER_HOST` -- Bind address (default: 0.0.0.0)
- `SERVER_PORT` -- Port (default: 8080)

### Known Issues / Tech Debt
1. E2E encryption is Signal Protocol but NOT production-audited. Private keys still in SharedPreferences (should use flutter_secure_storage / platform keystore)
2. Session keys cached forever in memory (no TTL expiration)
3. No proper multi-device support yet (device_id column exists but single-device in practice)
4. Group messages are NOT encrypted (sent as plaintext, only DMs use E2E)
5. `core/rust-core/src/api.rs` has `todo!()` stubs -- FFI bridge not yet integrated
6. Rate limiting is in-memory only (resets on server restart)
7. 15-second conversation polling timer exists as safety net but shouldn't be needed with WebSocket

### Test Coverage
- Rust core: 41 tests (Signal Protocol)
- Server: 12 tests (JWT, auth, refresh tokens)
- Client: 51 tests (crypto, models, state)
- Total: 104 tests

### File Structure
```
apps/
  client/          -- Flutter app (web + desktop)
    lib/src/
      models/      -- Data models (conversation, contact, chat_message, reaction)
      providers/   -- Riverpod state management
      screens/     -- Full-screen views
      widgets/     -- Reusable components
      services/    -- Crypto, notifications, sound
      theme/       -- EchoTheme + EchoColorExtension
      utils/       -- Shared utilities (crypto_utils, time_utils)
    web/           -- Web-specific assets (index.html, favicon, manifest)
    test/          -- Flutter tests
  server/          -- Rust Axum server
    src/
      auth/        -- JWT, middleware
      db/          -- SQLx queries + migrations
      routes/      -- REST + WebSocket handlers
      ws/          -- WebSocket hub + message handler
      middleware/   -- Rate limiting
core/
  rust-core/       -- Shared Rust library
    src/signal/    -- Signal Protocol (X3DH, Double Ratchet, sessions)
infra/
  docker/          -- Docker compose files (dev + prod)
scripts/           -- run.sh, demo scripts
public/            -- Brand assets (icons)
docs/              -- Self-hosting guide
```
