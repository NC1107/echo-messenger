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
