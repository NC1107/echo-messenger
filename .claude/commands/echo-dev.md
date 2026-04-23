---
description: Echo Messenger development workflow — enforces project standards for tests, commits, a11y, and CI compliance
argument-hint: <task description, e.g. "fix message delivery bug" or "add emoji picker">
---

# Echo Development Workflow

You are working on Echo Messenger. Follow these project-specific standards rigorously. Every rule exists because we've been burned by ignoring it.

## 0. Model Routing (Token Efficiency)

Use the Agent tool's `model` parameter to route work to the cheapest capable model:

- **Haiku** (`model: "haiku"`): File searches, grep/glob operations, reading files for context, running lint/format checks, simple edits (typos, renames, label additions), git status/diff/log commands
- **Sonnet** (`model: "sonnet"`): Writing tests from established patterns, applying well-defined fixes, widget modifications following existing conventions, migration files, config changes
- **Opus** (default, no override): Complex logic changes, security-sensitive code (crypto, auth), architectural decisions, novel implementations, debugging race conditions, multi-file refactors

When spawning subagents for parallel work, always set the model. Don't use Opus for a file search.

## 1. Branch & Safety

- **Always work on `dev`**. Never push directly to `main` unless explicitly told it's a hotfix.
- Check `git status` before starting. Stash or commit unrelated changes.
- If fixing a bug, prefix your branch or commit with `fix:`. If adding a feature, use `feat:`.

## 2. Test-First for Bugs (Prove It's Broken, Then Fix It)

When fixing a bug:

1. **Write a failing test first** that reproduces the exact bug.
   - Rust: add to the relevant `apps/server/tests/api_*.rs` file or create one.
   - Flutter: add to the relevant `apps/client/test/` file.
2. **Run the test** — confirm it fails for the right reason.
3. **Fix the bug** — minimal change targeting root cause.
4. **Run the test again** — confirm it passes.
5. **Run the full suite** to check for regressions.

This is non-negotiable. A bug fix without a regression test is incomplete.

## 3. Test-After for Features

When adding a feature:

1. Implement the feature.
2. **Write tests immediately** — before committing, before moving on.
   - Server routes: integration test in `apps/server/tests/api_*.rs`
   - Client providers: unit test in `apps/client/test/providers/`
   - Client widgets: widget test in `apps/client/test/widgets/`
   - New screens: at minimum, test that the screen renders without errors.
3. Match the existing test patterns — use `common::spawn_server()` for Rust, `pumpApp`/`pumpWidget` with `standardOverrides()` for Flutter.

## 4. Commit Standards

**Format**: Conventional commits, lowercase subject, max 72 chars.

```
type(scope): short description

Optional body (keep brief).
```

**Allowed types**: `feat fix docs style refactor perf test build ci chore revert security`
**Optional scopes**: `core server client infra proto crypto ci deps`

**Rules**:
- No `Co-Authored-By` tags. Ever. This is our convention.
- No multi-paragraph explanations or bullet lists in commit messages.
- One line subject. Optional brief body. That's it.
- If a pre-commit hook fails, fix the issue and create a NEW commit (never amend).

**Examples from this repo**:
```
fix: Signal Protocol session establishment -- Alice/Bob role detection
feat(client): threaded replies with thread view panel and reply count badges
refactor: upgrade theme to ThemeExtension for scalable custom themes
security: audit fixes, integration tests, and accessibility labels
```

## 5. Semantic Labels & Accessibility

Every new interactive widget MUST have proper accessibility:

- **IconButton**: always include `tooltip:` parameter
- **TextField/TextFormField**: always include `labelText:` in InputDecoration
- **GestureDetector on interactive elements**: wrap in `Semantics` or prefer `InkWell`
- **Switch/Checkbox**: use `SwitchListTile` which inherits title as label
- **Custom buttons**: wrap in `Semantics(button: true, label: '...')`
- **Images**: include `semanticLabel:` parameter

Before committing widget changes, grep for `IconButton(` without `tooltip:` and `TextField(` without `labelText:` in your changed files.

## 6. Pipeline Compliance (Pre-Push Checklist)

Your code MUST pass all CI checks. Verify locally or be confident:

### Rust (server + core)
```bash
cargo fmt --all -- --check          # Format (max_width=100, edition 2024)
cargo clippy --workspace --all-targets -- -D warnings  # Lint (zero warnings)
cargo test --workspace              # Tests pass
```

**Common gotchas**:
- `rustfmt` at max_width=100 — lines that fit in 101 chars will fail CI
- Clippy `manual_range_contains` — use `(a..=b).contains(&x)` not `x >= a && x <= b`
- Clippy `-D warnings` — any warning is a build failure
- New SQL columns need migration files in `apps/server/migrations/`

### Flutter (client)
```bash
cd apps/client
dart format --set-exit-if-changed .  # Format
flutter analyze --fatal-infos       # Lint (zero infos)
flutter test                        # Tests pass
```

**Common gotchas**:
- Unused imports are fatal (`flutter analyze --fatal-infos`)
- New providers need `biometricOverride()` in tests if PrivacySection is involved
- `pumpAndSettle` timeouts if loading indicators are animating — mock the provider
- `scrollUntilVisible` fails on lazy `ListView` items that aren't built — use `skipOffstage: false` or restructure

### Lefthook pre-commit (runs automatically)
- Rust: cargo fmt + clippy on `.rs` files
- Dart: dart format + flutter analyze on `.dart` files
- Commitlint: validates commit message format

## 7. File Organization

- Server routes → `apps/server/src/routes/`
- Server DB queries → `apps/server/src/db/`
- Server tests → `apps/server/tests/api_*.rs`
- Client screens → `apps/client/lib/src/screens/`
- Client widgets → `apps/client/lib/src/widgets/`
- Client providers → `apps/client/lib/src/providers/`
- Client services → `apps/client/lib/src/services/`
- Client tests → `apps/client/test/` (mirrors lib structure)
- Migrations → `apps/server/migrations/YYYYMMDDHHMMSS_name.sql`

## 8. Theme Compliance

- Use `context.accent`, `context.textPrimary`, `context.surface`, etc. from the ThemeExtension
- **Never** hardcode `EchoTheme.accent` or `EchoTheme.textMuted` — these are legacy static aliases that don't adapt to the active theme
- **Never** hardcode colors like `Colors.white`, `Color(0xFF...)` — use theme tokens
- New widgets must look correct in dark, light, and high-contrast themes

## 9. WebSocket Conventions

- **Always** use ticket-based auth for WebSocket (`?ticket=`, never `?token=` with JWT)
- **Always** use ticket-based auth for media downloads when possible
- Message wire format is versioned (V1/V2) — don't change without updating both server and client

## 10. When You're Done

Before requesting review or pushing:

1. `git diff` — review your own changes
2. Run relevant test suites
3. Check for console.log / debugPrint / print statements left behind
4. Check for TODO comments you introduced — either resolve them or file an issue
5. Verify semantic labels on new interactive widgets
6. Verify theme compliance (no hardcoded colors)
7. Commit with proper conventional commit format (no co-author)
