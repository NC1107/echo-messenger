# Echo - Encrypted Messenger

A lightweight, cross-platform messaging app with end-to-end encryption. Discord-level UX with Signal-level privacy.

## Downloads

Get the latest build from the [Releases page](https://github.com/NC1107/echo-messenger/releases).

| Platform | Download |
|----------|----------|
| Windows | [Echo-Setup-x64.exe](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-Setup-x64.exe) (installer) |
| Linux | [Echo-x86_64.AppImage](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-x86_64.AppImage) (single file) |
| Web | [echo-web.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-web.tar.gz) (static files) |
| Server | [echo-server-linux-x64.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-server-linux-x64.tar.gz) |
| Docker | `ghcr.io/nc1107/echo-messenger/server:latest` |

## Features

- **End-to-end encryption** -- X25519 key exchange + AES-256-GCM. Server never sees plaintext.
- **1:1 and group messaging** -- Real-time via WebSocket
- **Conversations list** -- Last message preview, unread badges, timestamps
- **Typing indicators** -- See when someone is typing
- **Message reactions** -- Long-press to react with emoji
- **Message grouping** -- Consecutive messages grouped with date separators
- **Cross-platform** -- Windows, Linux, Web
- **Lightweight** -- <80MB RAM idle (vs Discord's 500MB+)

## Status

**Phase 2 complete.** Core chat experience is functional.

| Component | Status |
|-----------|--------|
| User auth (Argon2id + JWT) | Working |
| 1:1 encrypted messaging | Working |
| Group messaging | Working (unencrypted) |
| Contacts system | Working |
| Typing indicators | Working |
| Message reactions | Working |
| Conversations list | Working |
| Message history | Working |
| E2E encryption | Working (1:1 only) |
| CI/CD pipelines | All green |
| Multi-OS releases | Automated |

## Architecture

```
Flutter Client (Linux, Windows, Web)
  ├── Riverpod state management
  ├── WebSocket real-time messaging
  └── Client-side E2E encryption (X25519 + AES-256-GCM)

Rust Server (axum + PostgreSQL)
  ├── REST API (auth, contacts, groups, messages)
  ├── WebSocket hub (message relay, typing, reactions)
  └── Stores only ciphertext (zero-knowledge)

Rust Core Library
  ├── X25519 key exchange
  ├── AES-256-GCM encryption
  ├── X3DH session establishment
  └── 22 unit tests
```

## Quick Start

```bash
# Clone
git clone https://github.com/NC1107/echo-messenger.git
cd echo-messenger

# Start everything (DB + server + two app instances)
./scripts/run.sh

# Or manually:
cd infra/docker && docker compose up -d    # Start PostgreSQL
cargo run -p echo-server                    # Start server
cd apps/client && flutter run -d linux      # Start client
```

## Development

See [docs/setup.md](docs/setup.md) for full setup instructions.

### Prerequisites
- Rust (stable)
- Flutter 3.41+
- Docker (for PostgreSQL)
- Node.js 20+ (for commitlint)

### Running Tests
```bash
cargo test --workspace          # 22 Rust tests
cd apps/client && flutter test  # 41 Flutter tests
./scripts/test_e2e.sh          # 20 E2E integration tests
npx playwright test            # Playwright visual tests
```

## Security

Messages are encrypted client-side before sending. The server stores and relays only ciphertext. See [docs/SECURITY.md](docs/SECURITY.md).

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
