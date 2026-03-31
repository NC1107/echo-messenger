# Contributing

## Setup

See `docs/setup.md` for local development setup.

## Workflow

1. Branch from `dev`: `git checkout -b feat/your-feature dev`
2. Follow conventional commits: `feat(core): add message encryption`
3. Run `cargo fmt && cargo clippy` before committing
4. Open PR against `dev`

## Code Standards

### Rust
- `cargo fmt` (enforced by CI)
- Zero clippy warnings
- No `.unwrap()` in production code

### Dart
- `dart format` (enforced by CI)
- Zero analyzer warnings
