---
description: Fix a bug in Echo Messenger with mandatory reproduction test before the fix
argument-hint: <bug description or issue number>
---

# Echo Bug Fix Workflow

You are fixing a bug in Echo Messenger. The reproduction test comes FIRST.

## Phase 1: Understand

1. Read the bug description carefully.
2. Identify which layer is affected: server (Rust), client (Flutter), or both.
3. Find the relevant source files.

## Phase 2: Reproduce with a Test

**Write a failing test BEFORE touching any production code.**

### Server bugs
- Add a test to `apps/server/tests/api_*.rs` (integration) or inline `#[cfg(test)]` (unit).
- Use `common::spawn_server()`, `common::register_and_login()`.
- Assert the broken behavior — the test must FAIL.

### Client bugs
- Add a test to `apps/client/test/` matching the source file structure.
- Use `pumpApp`/`pumpWidget` with `standardOverrides()`.
- Assert the broken behavior — the test must FAIL.

### If untestable
- If the bug is purely visual or requires manual interaction, document the reproduction steps as a comment in the test file with `skip: 'requires manual verification'`.
- Still write the test — just skip it. The structure helps future maintainers.

## Phase 3: Fix

1. Make the minimal change to fix the root cause.
2. Don't fix adjacent issues — file them separately.
3. Don't refactor surrounding code.

## Phase 4: Verify

1. Run the reproduction test — it must now PASS.
2. Run the full suite for the affected layer:
   - `cargo test --workspace` for Rust
   - `cd apps/client && flutter test` for Flutter
3. Check formatting:
   - Rust: lines under 100 chars, `(a..=b).contains(&x)` pattern
   - Dart: `dart format` clean, no unused imports

## Phase 5: Commit

```
fix(scope): short description of what was broken

Closes #NNN (if applicable)
```

- No `Co-Authored-By` tags
- Lowercase subject, max 72 chars
- Optional brief body explaining root cause

## Checklist

- [ ] Reproduction test written and confirmed failing
- [ ] Fix applied (minimal change)
- [ ] Reproduction test now passes
- [ ] Full test suite passes
- [ ] Format/lint clean
- [ ] Semantic labels on any new widgets
- [ ] Theme-aware colors (no hardcoded values)
- [ ] Conventional commit, no co-author
