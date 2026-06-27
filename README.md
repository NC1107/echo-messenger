# Echo - Encrypted Messenger

<!-- social-badges:start -->
[![Discord](https://img.shields.io/badge/Discord-5865F2?logo=discord&logoColor=white)](https://discord.gg/jUMuSxGf6q)
[![GitHub](https://img.shields.io/badge/GitHub-181717?logo=github&logoColor=white)](https://github.com/NC1107)
[![Patreon](https://img.shields.io/badge/Patreon-F96854?logo=patreon&logoColor=white)](https://patreon.com/NPC1107)
<!-- social-badges:end -->

[![Release](https://img.shields.io/github/v/release/NC1107/echo-messenger?label=latest)](https://github.com/NC1107/echo-messenger/releases/latest)
[![Release](https://github.com/NC1107/echo-messenger/actions/workflows/release.yml/badge.svg)](https://github.com/NC1107/echo-messenger/actions/workflows/release.yml)
[![Rust CI](https://github.com/NC1107/echo-messenger/actions/workflows/rust-ci.yml/badge.svg)](https://github.com/NC1107/echo-messenger/actions/workflows/rust-ci.yml)
[![Flutter CI](https://github.com/NC1107/echo-messenger/actions/workflows/flutter-ci.yml/badge.svg)](https://github.com/NC1107/echo-messenger/actions/workflows/flutter-ci.yml)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=NC1107_echo-messenger&metric=coverage)](https://sonarcloud.io/summary/new_code?id=NC1107_echo-messenger)
[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)](LICENSE)

A lightweight, cross-platform messaging app with end-to-end encryption. I'm not a fan of the direction Discord is moving, and I don't think most people can set up Matrix, so this is my attempt at a replacement. It runs centralized by default, but you can always host the server yourself.

## Downloads

Client apps and server binaries are on the [Releases page](https://github.com/NC1107/echo-messenger/releases).

**Client apps**

| Platform | Download |
|----------|----------|
| Windows | [Echo-Setup-x64.exe](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-Setup-x64.exe) (installer -- see [SmartScreen workaround](docs/SMARTSCREEN_WORKAROUND.md)) |
| Linux | [Echo-x86_64.AppImage](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-x86_64.AppImage) (single file), or `.deb` / `.rpm` from the [Releases page](https://github.com/NC1107/echo-messenger/releases/latest) (see below) |
| macOS | [echo-macos-x64.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-macos-x64.tar.gz) (extract and run `Echo.app`) |
| Web | [echo-messenger.us](https://echo-messenger.us) (hosted) or [echo-web.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-web.tar.gz) (self-host static files) |
| iOS | Available via TestFlight — see [ios-testflight-setup.md](docs/ios-testflight-setup.md) |
| Android | APK on the [Releases page](https://github.com/NC1107/echo-messenger/releases) (sideload) |

**Linux packages (`.deb` / `.rpm`)**

Install through your package manager so Echo updates and uninstalls like any
other app (runtime libraries are pulled in as dependencies). Download the file
for your distro from the [latest release](https://github.com/NC1107/echo-messenger/releases/latest), then:

```bash
# Fedora / RHEL / openSUSE
sudo dnf install ./echo-messenger-*.x86_64.rpm

# Debian / Ubuntu
sudo apt install ./echo-messenger_*_amd64.deb
```

Launch it as **Echo Messenger** from your app menu, or run `echo-messenger` from a terminal.

**Self-hosting the server**

| Method | Source |
|--------|--------|
| Binary | [echo-server-linux-x64.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-server-linux-x64.tar.gz) |
| Docker (server) | `ghcr.io/nc1107/echo-messenger/server:latest` |
| Docker (web) | `ghcr.io/nc1107/echo-messenger/web:latest` |

## Features

- **Private by default** -- Your messages are end-to-end encrypted. The server stores and relays only ciphertext; it cannot read what you send.
- **1:1 and group messaging** -- Real-time direct messages and group chats, all in one place.
- **Groups** -- Create public or private groups, manage members with owner/admin roles, share invite links.
- **Find communities** -- Browse and join public groups without needing an invite.
- **Media sharing** -- Send images, videos, and PDFs. Inline previews with a fullscreen lightbox.
- **Universal search** -- Search across messages, contacts, and groups in one place.
- **Edit and delete** -- Fix mistakes or pull a message; changes sync to everyone in real-time.
- **Reactions** -- React to any message with emoji.
- **@mentions** -- @username autocomplete in groups; @everyone and @here for announcements.
- **Invite links and QR codes** -- Share a link or QR code to let someone add you as a contact instantly.
- **Privacy controls** -- Toggle read receipts on or off.
- **Typing indicators** -- See when someone is composing a reply.
- **Cross-platform** -- Windows, Linux, Web, iOS, Android.
- **Lightweight** -- Under 150 MB RAM idle (vs Discord's 500 MB+).

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

## Self-Hosting

Echo is designed to be self-hosted. See [self-hosting.md](docs/self-hosting.md) for a step-by-step guide covering Docker Compose, Traefik, TLS, and environment configuration.

## Privacy and Encryption

Direct messages use the **Signal Protocol** (X3DH + Double Ratchet) -- the same encryption used by Signal and WhatsApp. Every message gets a unique key; compromising one key does not expose past or future messages. Your private keys never leave your device.

For technical details -- key exchange diagrams, wire format, security properties, and key storage -- see [encryption.md](docs/encryption.md).

To report a vulnerability see [SECURITY.md](docs/SECURITY.md).

## Development

See [setup.md](docs/setup.md) for full environment setup.

### Prerequisites
- Rust (edition 2024)
- Flutter 3.41+
- Docker (for PostgreSQL)
- Node.js 20+ (for commitlint)

### Running Tests
```bash
cargo test --workspace                        # Rust tests
cd apps/client && flutter test                # Flutter tests
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

[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0). See [LICENSE](LICENSE).

This is a **source-available** license — anyone may use, modify, and contribute to Echo for any **non-commercial** purpose (personal, hobby, educational, non-profit, public-research, religious). Selling it, hosting it as a paid service, or using it inside a commercial entity is **not permitted** without a separate commercial license from the copyright holder.

Contributions are welcome via pull request. By submitting a contribution you agree that your changes are released under the same license.
