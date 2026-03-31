# Echo - Decentralized Encrypted Messenger

A lightweight, cross-platform messaging app with end-to-end encryption.

## Status

Phase 1 MVP - Vertical Slice (in development)

## Architecture

- **Rust shared core** (`core/rust-core/`): encryption (Signal Protocol), networking, local storage (SQLCipher)
- **Flutter desktop client** (`apps/client/`): Windows + Linux
- **Rust server** (`apps/server/`): axum + PostgreSQL

## Quick Start

See [docs/setup.md](docs/setup.md) for development setup.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
