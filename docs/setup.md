# Local Development Setup

## Prerequisites

- Rust (latest stable): `rustup`
- Flutter 3.41+
- Docker + Docker Compose
- Node.js 20+ (for commitlint)

## Quick Start

```bash
# Start database
cd infra/docker && docker compose up -d

# Build Rust workspace
cargo build --workspace

# Run server
cd apps/server && cargo run

# Run client (another terminal)
cd apps/client && flutter pub get && flutter run -d linux
```

## Environment

Copy `.env.example` to `.env` at the project root. The server reads environment variables from `.env`.

## Username DM invite links and QR add flow

- Direct-message invites use username links: `https://echo-messenger.us/#/u/{username}`
- The in-app **Safety Number** screen now includes an **Add Contact** mode that shows this DM invite as a QR code.
- In **Add Contact** mode you can copy or share your invite link and have others scan it to add/message you.
- Group invites are unchanged and continue to use `https://echo-messenger.us/#/join/{groupId}`.
