---
description: Add a feature to Echo Messenger with tests, a11y, and pipeline compliance
argument-hint: <feature description or issue number>
---

# Echo Feature Workflow

You are adding a feature to Echo Messenger. Tests and accessibility are not optional.

## Phase 1: Plan

1. Identify which layers are affected (server, client, both).
2. List the files you'll create or modify.
3. If adding a new API endpoint, plan the integration test.
4. If adding a new widget/screen, plan the widget test.

## Phase 2: Implement

### Server changes
- Routes in `apps/server/src/routes/` with handler functions
- DB queries in `apps/server/src/db/` (parameterized, never raw string interpolation)
- Migrations in `apps/server/migrations/YYYYMMDDHHMMSS_name.sql`
- Register routes in `apps/server/src/routes/mod.rs`

### Client changes
- Screens in `apps/client/lib/src/screens/`
- Widgets in `apps/client/lib/src/widgets/`
- State in `apps/client/lib/src/providers/` (Riverpod StateNotifier + immutable copyWith)
- Services in `apps/client/lib/src/services/`

## Phase 3: Test (immediately after implementation)

### Server
- Integration test in `apps/server/tests/api_*.rs`
- Cover: success case, auth required (401), invalid input (400), unauthorized access (403/404)
- Use `common::spawn_server()`, `common::register_and_login()`

### Client
- Provider test: state transitions, API calls with mock HTTP
- Widget test: renders correctly, user interactions work, loading/error/empty states
- Use `pumpApp`/`pumpWidget` with `standardOverrides()`

## Phase 4: Accessibility & Theme

For every new interactive widget:
- [ ] `IconButton` has `tooltip:`
- [ ] `TextField` has `labelText:` in InputDecoration
- [ ] Interactive areas use `InkWell` (not bare `GestureDetector`) for tap feedback
- [ ] Touch targets are minimum 44x44px
- [ ] Colors use `context.accent`, `context.textPrimary`, etc. (no `EchoTheme.` statics, no `Colors.white`)
- [ ] Animations respect `MediaQuery.of(context).disableAnimations`
- [ ] Empty states have guidance text and action buttons
- [ ] Loading states use skeleton loaders or progress indicators

## Phase 5: Pipeline Check

**CRITICAL**: Subagents cannot hand-format Dart code reliably. After ANY agent edits .dart files, you MUST run `dart format` on those files before committing. Never trust "format clean" claims without running the tool.

Before committing, verify:
- [ ] `dart format` run on ALL changed .dart files (not optional — agents get this wrong)
- [ ] `cargo fmt --all -- --check` passes (max_width=100)
- [ ] `cargo clippy --workspace --all-targets -- -D warnings` passes
- [ ] `flutter analyze --fatal-infos` passes
- [ ] All tests pass

## Phase 6: Commit

```
feat(scope): short description

Optional brief body.
```

- No `Co-Authored-By` tags
- Lowercase subject, max 72 chars
- Scopes: core, server, client, infra, proto, crypto, ci, deps
