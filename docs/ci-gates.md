# CI Gates Runbook

This document lists every required CI gate for the `main` branch, what it
tests, why it is required, and what an admin must configure in GitHub to
enforce it.

---

## Required status checks (must be set in branch protection)

These are the **exact check names** to add under
**Settings → Branches → main → Require status checks to pass before merging**.

| Check name | Workflow file | Blocks on |
|---|---|---|
| `Flutter CI / Summary` | `.github/workflows/flutter-ci.yml` | Format, analyze, unit tests, 41 % coverage floor, Linux + Android smoke builds |
| `Rust CI / Summary` | `.github/workflows/rust-ci.yml` | `rustfmt`, `clippy -D warnings`, full `cargo test` suite |
| `E2E Tests / Summary` | `.github/workflows/e2e.yml` | Playwright smoke lane (`local_full.spec.ts`) against a live server + web client |

> **Why summary jobs?** GitHub branch protection must reference a single stable
> check name. Because each workflow has multiple parallel jobs (e.g.
> `check / smoke-linux / smoke-android`), a `summary` job that depends on all
> of them gives branch protection a single, stable target. If any upstream job
> fails, `summary` fails too.

---

## Gate details

### Flutter CI / Summary

**File**: `.github/workflows/flutter-ci.yml`

Jobs that must all pass:

| Job | What it checks |
|---|---|
| `check` (Analyze + Test) | `dart format`, `flutter analyze --fatal-infos`, `flutter test --coverage`, **41 % line-coverage floor** (ratcheting baseline, last bumped 2026-04-30), Codecov upload with `fail_ci_if_error: true` |
| `smoke-linux` | `flutter build linux --debug` compiles without error |
| `smoke-android` | `flutter build apk --debug` compiles without error |

**Coverage threshold**: 41.0 % (hardcoded in the `Check coverage threshold` step).
Raise the threshold in `flutter-ci.yml` after coverage genuinely improves — never
lower it. The ratchet comment in the file records the date of the last bump.

**Codecov**: `fail_ci_if_error: true` — a Codecov upload failure blocks the PR.
If Codecov is unreachable and you need to bypass temporarily, set
`fail_ci_if_error: false` in the step, merge the fix, then revert.

---

### Rust CI / Summary

**File**: `.github/workflows/rust-ci.yml`

| Job | What it checks |
|---|---|
| `check` (Format + Lint + Test) | `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace` (250+ tests including Signal Protocol + server integration against a live PostgreSQL instance) |

Rust coverage is handled by SonarCloud (push-only, not a PR gate — see
[SonarCloud gate](#sonarcloud-advisory-not-required) below).

---

### E2E Tests / Summary

**File**: `.github/workflows/e2e.yml`

| Lane | Required? | Notes |
|---|---|---|
| `smoke` (`--project=smoke`) | **Yes** — gates `summary` | `local_full.spec.ts` — full feature flow end-to-end. `--retries=1` absorbs single-flake noise. |
| `maintained` (`--project=maintained`) | No — `continue-on-error: true` | Deeper UI specs; soft-fail pending #673 (CanvasKit `getByRole` brittleness). Flip to required once #673 is resolved. |

The `summary` job only declares `needs: [e2e]` (the single job that runs both
lanes). The smoke lane failing will cause the `e2e` job to exit non-zero, which
causes `summary` to fail.

---

## SonarCloud (advisory, not required)

**File**: `.github/workflows/sonarcloud.yml`

Runs on push to `main` and `dev` only (not on pull requests — token-exfiltration
risk; see comment at top of that file). Provides Rust + Flutter coverage to
SonarCloud and surfaces quality gate status there. Not wired into branch
protection because it does not run on PRs.

To add SonarCloud as a PR gate in future:
1. Split into a `pull_request` artifact job (no token) + `workflow_run` consumer
   job (token in clean environment) — see the comment in `sonarcloud.yml` for
   guidance.
2. Add the resulting check name to branch protection.

---

## Integration test harness (advisory)

`apps/client/integration_test/` does not currently contain a test file.
The `integration_test` directory itself is referenced in issue #537 as a
misleading shell harness. Until a meaningful app-level integration test exists
and runs reliably in CI, this is **not** a merge gate. When promoted, add it as
a new job in `flutter-ci.yml` or a dedicated workflow and add its summary check
to branch protection.

---

## Admin checklist — enabling branch protection

The workflows surface the correct check names automatically once they have run
at least once on `main`. An admin must then:

1. Go to **github.com/NC1107/echo-messenger → Settings → Branches**.
2. Add a branch protection rule for `main` (or edit the existing one).
3. Enable **"Require status checks to pass before merging"**.
4. Enable **"Require branches to be up to date before merging"**.
5. Search for and add each required check from the table above:
   - `Flutter CI / Summary`
   - `Rust CI / Summary`
   - `E2E Tests / Summary`
6. Enable **"Do not allow bypassing the above settings"** (optional but
   recommended for the `main` branch).
7. Optionally add the security workflow checks:
   - `Security / audit` (from `security.yml`) — already fails hard on
     `cargo audit` and `cargo deny` findings.

> Branch protection cannot be set from CI without an admin-scoped token.
> The settings above require manual action in the GitHub UI by a repository
> admin.

---

## Raising the coverage floor

When Flutter unit test coverage improves:

1. Run `flutter test --coverage` locally and note the new percentage.
2. Edit `.github/workflows/flutter-ci.yml`, `Check coverage threshold` step:
   change `threshold = 41.0` to the new value (round down to the nearest
   integer).
3. Update the comment above the threshold to record the bump date.
4. Commit as `ci(client): raise coverage floor to <N>%`.

Never lower the threshold. If coverage drops, the PR that caused the drop
must add tests to restore it before merging.
