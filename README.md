# Echo - Encrypted Messenger

A lightweight, cross-platform messaging app with end-to-end encryption. I'm not a fan of the direction discord is moving, and I don't think most people can setup Matrix, so this is my attempt at a replacement. I will be setting it up by default centralized, but there is always an option to host the server yourself.

## Downloads

Get the latest build from the [Releases page](https://github.com/NC1107/echo-messenger/releases).

| Platform | Download |
|----------|----------|
| Windows | [Echo-Setup-x64.exe](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-Setup-x64.exe) (installer) |
| Linux | [Echo-x86_64.AppImage](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-x86_64.AppImage) (single file) |
| Web | [echo-messenger.us](https://echo-messenger.us) or [echo-web.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-web.tar.gz) (static files) |
| Server | [echo-server-linux-x64.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-server-linux-x64.tar.gz) |
| Docker | `ghcr.io/nc1107/echo-messenger/server:latest` |

## Features

- **End-to-end encryption** -- Signal Protocol (X3DH + Double Ratchet).
- **1:1 and group messaging** -- Real-time via WebSocket
- **Group management** -- Public/private groups, owner/admin roles, kick members, edit group name, invite links
- **Public group discovery** -- Browse and join public groups with membership badges
- **Media sharing** -- Upload images, videos, PDFs. Inline image previews with lightbox viewer.
- **Message editing and deletion** -- Edit/delete your messages, changes propagate in real-time
- **Message reactions** -- Tap to react with emoji
- **Privacy controls** -- Toggle read receipts
- **Per-message encryption indicator** -- Lock icon shows which messages were encrypted
- **Typing indicators** -- See when someone is typing
- **Conversations list** -- Last message preview, unread badges, timestamps
- **Cross-platform** -- Windows, Linux, Web, iOS, Android
- **Lightweight** -- <150MB RAM idle (vs Discord's 500MB+)

## Status

| Component | Status |
|-----------|--------|
| User auth (Argon2id + JWT) | Working |
| 1:1 messaging | Working |
| Group messaging | Working |
| E2E encryption (Signal Protocol) | Working (optional per-conversation) |
| Encryption toggle + WS sync | Working |
| Contacts system | Working |
| Media upload/download | Working |
| Message edit/delete | Working |
| Group owner management | Working |
| Public group discovery | Working |
| Privacy settings | Working |
| Typing indicators | Working |
| Message reactions | Working |
| CI/CD pipelines | Working |
| Multi-OS releases | Automated |

## Architecture

```
Flutter Client (Linux, Windows, Web)
  ├── Riverpod state management
  ├── GoRouter navigation
  ├── WebSocket real-time messaging
  └── Signal Protocol encryption (X3DH + Double Ratchet)

Rust Server (Axum + PostgreSQL)
  ├── REST API (auth, contacts, groups, messages, media, privacy)
  ├── WebSocket hub (message relay, typing, reactions, encryption sync)
  ├── JWT auth (15-min access + 7-day refresh tokens)
  ├── Argon2id password hashing
  └── 15 auto-applied SQL migrations

Deployment
  ├── Docker + Traefik reverse proxy
  ├── Watchtower auto-updates
  ├── Cloudflare CDN
  └── GitHub Actions CI/CD (lint, test, build, release)
```

## Security

Encryption is implemented using the Signal Protocol (X3DH key exchange + Double Ratchet). Encryption is **optional per-conversation** -- users toggle it via a lock icon in the chat header. When enabled, messages are encrypted client-side before sending; the server stores and relays only ciphertext.

- **Encrypted DMs**: Signal Protocol (X3DH + Double Ratchet), AES-256-GCM per-message
- **Plaintext DMs**: Available when encryption is toggled off
- **Group messages**: Currently plaintext (group encryption is planned)
- **Media**: Any authenticated user can download media by UUID (conversation-based ACL planned)
- **Passwords**: Argon2id with per-user salts
- **Tokens**: Short-lived JWT (15 min) + refresh tokens (7 days)

Known limitations:
- ~~Private keys stored in SharedPreferences~~ Resolved: migrated to flutter_secure_storage (platform keystore)
- Session keys cached in memory with no TTL
- No forward secrecy for one-time prekeys (OTP private keys not yet persisted)

See [docs/SECURITY.md](docs/SECURITY.md) for reporting vulnerabilities.

## Quick Start

```bash
# Clone
git clone https://github.com/NC1107/echo-messenger.git
cd echo-messenger

# Start everything (DB + server + test user)
./scripts/run.sh

# Or manually:
cd infra/docker && docker compose up -d    # Start PostgreSQL
cargo run -p echo-server                    # Start server on :8080
cd apps/client && flutter run -d linux      # Start client
```

## Development

See [docs/setup.md](docs/setup.md) for full setup instructions.

### Prerequisites
- Rust (edition 2024)
- Flutter 3.41+
- Docker (for PostgreSQL)
- Node.js 20+ (for commitlint)

### Running Tests
```bash
cargo test --workspace                        # 53 Rust tests
cd apps/client && flutter test                # 55 Flutter tests
./scripts/test_e2e.sh                         # E2E integration tests
npx playwright test                           # Visual tests
```

### Lint & Format
```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets
cd apps/client && dart format --set-exit-if-changed .
cd apps/client && flutter analyze --fatal-infos
```

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
