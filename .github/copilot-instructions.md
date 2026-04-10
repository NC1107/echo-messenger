# Echo Messenger — Copilot Instructions

Encrypted cross-platform chat app (Discord alternative). Rust/Axum server + Flutter client.
Full context: [CLAUDE.md](../CLAUDE.md) | Docs: [docs/](../docs/)

## Build & Test

```bash
# Local dev (PostgreSQL + server + test user)
./scripts/run.sh

# Server only
cd infra/docker && docker compose up -d   # PostgreSQL 17 on :5432
cargo run -p echo-server                   # :8080

# Flutter client
cd apps/client && flutter pub get && flutter run -d linux

# Tests
cargo test --workspace                     # Rust (53 tests)
cd apps/client && flutter test             # Flutter (55 tests)
npx playwright test                        # E2E (tests/e2e/)

# Lint
cargo fmt --all -- --check && cargo clippy --workspace --all-targets
cd apps/client && dart format --set-exit-if-changed . && flutter analyze --fatal-infos
```

## Git Workflow

- **Always work on `dev`**. Never push directly to `main`.
- `git push origin dev` → triggers lint CI + dev builds
- `gh pr create --base main` → triggers full release pipeline + version bump
- Conventional commits enforced by lefthook + commitlint. Max 72 chars, lowercase subject.
- Types: `feat fix docs style refactor perf test build ci chore revert security`

## Architecture

- `apps/server/` — Rust + Axum + SQLx (PostgreSQL). Migrations in `apps/server/migrations/`.
- `apps/client/` — Flutter + Riverpod + GoRouter. State in `lib/src/providers/`.
- `core/rust-core/` — Shared Signal Protocol implementation (reference only; Dart is production).
- `infra/docker/` — Three compose files: dev, test (port 5433), prod (Traefik + LiveKit).

## Critical Gotchas

- **WebSocket auth**: ticket-based (`?ticket=`), never `?token=`. Client calls `POST /api/auth/ws-ticket` first.
- **Rust edition 2024**; `rustfmt` max_width=100.
- **Flutter web renderer**: CanvasKit is default in 3.22+. The `--web-renderer` flag no longer exists.
- **Server env required**: `DATABASE_URL` and `JWT_SECRET` (≥32 chars) — panics without them.
- **Soft deletes**: messages use `is_deleted` flag, not `DELETE`.
- **Group E2E crypto**: infrastructure exists (`group_crypto_service.dart`, `routes/group_keys.rs`) but is not fully wired.
- **FFI bridge**: `core/rust-core/src/api.rs` has `todo!()` stubs — not integrated.
- **Rate limiting**: in-memory only, resets on server restart.

## Code Style

- No emojis in code.
- Rust: follow existing patterns in `apps/server/src/` — `Result<T, AppError>`, `AuthUser` extractor.
- Flutter: immutable state with `copyWith`, functional components, no unnecessary UI libraries.
- Commit messages: concise, human-readable, no bullet lists, no co-author tags.

## Key Docs

- Setup & self-hosting: [docs/setup.md](../docs/setup.md), [docs/self-hosting.md](../docs/self-hosting.md)
- Contributing: [docs/CONTRIBUTING.md](../docs/CONTRIBUTING.md)
- Security: [docs/SECURITY.md](../docs/SECURITY.md)
- Tests plan: [tests/e2e/TEST_PLAN.md](../tests/e2e/TEST_PLAN.md)
