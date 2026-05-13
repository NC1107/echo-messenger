# DevOps / CI / Infra Audit — 2026-05-09

### Finding 1: Release pipeline does not push docker images under the new reserved tag (Cargo.toml edit not committed before docker build)
- **File**: .github/workflows/release.yml:565-597
- **Severity**: high
- **Description**: The `docker` job runs `sed -i '...version = "X.Y.Z"' apps/server/Cargo.toml core/rust-core/Cargo.toml` and then builds the image with `cache-from: type=gha`. Because the build context is `.` (the freshly checked-out workspace) and `Cargo.lock` is *not* updated to match, the `cargo build --release` inside `apps/server/Dockerfile` may either re-resolve and shift transitive versions vs. what `lint-test` already validated, or fail the `--locked`-style reproducibility expectation (Cargo will rewrite Cargo.lock for a workspace member version bump). Reproducibility breaks: the artifact tested in `lint-test` is not bit-identical to the artifact published to GHCR. Same issue in `build-server` (line 547-548). The version reserved by the `version` job is also derived from `git tag` *before* the Cargo.toml edit is committed, so any out-of-band query of the image's `--version` flag will mismatch what's in source.
- **Code**:
```yaml
- name: Set version in Cargo.toml
  run: |
    sed -i 's/^version = ".*"/version = "${{ needs.version.outputs.version }}"/' apps/server/Cargo.toml
    sed -i 's/^version = ".*"/version = "${{ needs.version.outputs.version }}"/' core/rust-core/Cargo.toml
```
- **Fix**: Either (a) inject version at runtime via `CARGO_PKG_VERSION` override / `--build-arg` and bake into a constant via `env!()`, or (b) after the `sed`, run `cargo update --workspace --offline` and assert no other lockfile drift; ideally bump the version in source and tag from that commit so the reserved tag SHA == the SHA built into images.
- **Effort**: medium

### Finding 2: GHCR push uses GITHUB_TOKEN with workflow-wide `packages: write` scope; web build job has no separate permissions block
- **File**: .github/workflows/release.yml:14-16, 599-647
- **Severity**: medium
- **Description**: `permissions:` is declared once at workflow level granting `contents: write` + `packages: write` to *every* job, including `lint-test`, `build-linux`, `build-windows`, etc. that don't push images or tags. Any compromised third-party action (e.g. `softprops/action-gh-release`, `subosito/flutter-action`) running in those jobs has unnecessary write scope to the org's container registry and to the repo. Best practice is to scope `packages: write` to only the `docker` and `build-web` jobs and `contents: write` only to `version` and `release`, with `permissions: contents: read` at the top.
- **Code**:
```yaml
permissions:
  contents: write
  packages: write
```
- **Fix**: Default the workflow to `permissions: { contents: read }` and add per-job `permissions:` blocks granting `contents: write` only to `version`/`release` and `packages: write` only to `docker`/`build-web`.
- **Effort**: small

### Finding 3: Dependabot has no auto-merge or grouping — backlog accumulates indefinitely
- **File**: .github/dependabot.yml:1-34
- **Severity**: medium
- **Description**: Config has four ecosystems each with `open-pull-requests-limit: 10` but no `groups:`, no `commit-message:` prefix mapping to commitlint, and no auto-merge mechanism. With four ecosystems × 10 PRs, the dashboard can hold 40 open PRs, which is exactly the failure mode being seen (10 stale Cargo/pub PRs, oldest from Apr 29). Each PR has to pass commitlint with a manually-written conventional message because the default `Bump foo from x to y` body is not a conformant subject (`build(deps):` prefix is needed). Without grouping, every minor flutter package bump opens a separate PR.
- **Code**:
```yaml
- package-ecosystem: cargo
  directory: /
  schedule:
    interval: weekly
  labels:
    - dependencies
  open-pull-requests-limit: 10
```
- **Fix**: Add `groups:` (e.g. group all minor/patch updates per ecosystem into a single weekly PR), set `commit-message: prefix: "build", include: "scope"` to match commitlint allowed types, and add a `dependabot-auto-merge.yml` workflow that auto-merges patch-only and dev-dep bumps once CI passes. Reduce `open-pull-requests-limit` to 3-5 per ecosystem.
- **Effort**: small

### Finding 4: cargo-deny multiple-versions set to `warn` — duplicate transitive crates never fail CI
- **File**: deny.toml:46
- **Severity**: low
- **Description**: `[bans] multiple-versions = "warn"` means cargo-deny prints duplicate dependency versions but exits 0. The release pipeline's `security-pre-release` job runs cargo-deny with the default action (which does fail on `deny`/`error` but not `warn`), so duplicate-version drift accumulates silently. This bloats the server binary (250+ tests, a Rust workspace this size easily ends up with 3-4 versions of `syn`, `windows-sys`, `hashbrown`). It also defeats the supply-chain hygiene guarantee cargo-deny is supposed to provide.
- **Code**:
```toml
[bans]
multiple-versions = "warn"
```
- **Fix**: Either set `multiple-versions = "deny"` and explicitly `skip` known unavoidable duplicates, or accept the drift and document it; current state is the worst of both worlds (noise without enforcement).
- **Effort**: small

### Finding 5: Watchtower auto-update on `:latest` with no canary, no rollback, no health gate
- **File**: infra/docker/docker-compose.prod.yml:106-112 (note); referenced host compose
- **Severity**: high
- **Description**: Per CLAUDE.md and the inline comment, prod runs a host-managed compose with `WEB_VERSION=latest` / `SERVER_VERSION=latest` and `containrrr/watchtower` recreates containers on every push to GHCR. This means: (a) any successful `release.yml` run immediately ships to all users, with no staging or smoke gate between GHCR push and prod cutover; (b) if the new container is unhealthy, watchtower has already torn down the previous one — there is no atomic rollback; (c) the `prod-smoke.yml` workflow exists but is `workflow_dispatch` only, so it never runs automatically post-deploy. Combined with the known IPv6 healthcheck silent-filter, a bad release can produce a 404 prod with no automated recovery.
- **Code**:
```yaml
# (host compose, referenced)
image: ghcr.io/.../server:${SERVER_VERSION}   # latest
```
- **Fix**: Add a post-`release` job that (a) waits 30s, (b) runs `prod-smoke.yml` automatically against echo-messenger.us, (c) on failure pages an alert. Better: cut over by tag (`v1.2.3`) via a deploy job with SSH or via watchtower's `WATCHTOWER_LIFECYCLE_HOOKS` health gate, and keep the previous image tag pinned for instant rollback.
- **Effort**: medium

### Finding 6: trufflehog pull_request scan has no `base`/`head` and runs the head-commit code path implicitly — also misses Dependabot pushes
- **File**: .github/workflows/security.yml:44-48
- **Severity**: medium
- **Description**: For `pull_request`, the action is invoked without `base`/`head`, relying on auto-detection. On a Dependabot PR (which is the bulk of incoming PRs given Finding 3), `pull_request` events from forks don't have access to secrets, but the trufflehog action's auto-mode scans the working tree only, missing historical commits. More importantly, `trufflehog` with `--only-verified` *only* flags secrets it can actively verify against the live API (e.g. by hitting `api.github.com`). Unverified high-entropy strings (private keys, JWT secrets, SSH keys not yet pushed elsewhere) are silently ignored. JWT_SECRET, APNS_AUTH_KEY_BASE64, ANDROID_KEYSTORE_BASE64, IOS_CERTIFICATE_BASE64 — all of these would be missed by `--only-verified` if accidentally committed.
- **Code**:
```yaml
- name: Scan for secrets (pull_request)
  if: github.event_name == 'pull_request'
  uses: trufflesecurity/trufflehog@... # v3.95.2
  with:
    extra_args: --only-verified
```
- **Fix**: Add a separate scan without `--only-verified` that fails on any high-entropy match in the diff (not full history) for PRs, and keep `--only-verified` for the full-history push scan. Also pass explicit `base: ${{ github.event.pull_request.base.sha }}` / `head: ${{ github.event.pull_request.head.sha }}` to make the range deterministic.
- **Effort**: small

### Finding 7: Server Dockerfile builds against `FROM rust:1.94.1-bookworm` builder but installs `ffmpeg` in the runtime image — bloats image and pulls a wide CVE surface
- **File**: apps/server/Dockerfile:28-33
- **Severity**: medium
- **Description**: The runtime stage installs `ffmpeg` from Debian. The full ffmpeg package on bookworm is ~250-400MB once expanded and pulls in dozens of media codec libraries (`libavcodec59`, `libavformat59`, `libx264`, etc.), each with its own CVE history. There is no comment in the Dockerfile or repo README explaining why the *server* needs ffmpeg (voice/video relay goes through LiveKit, not the server). If it's used for thumbnail generation, install `ffmpeg-static` or just `libavformat-dev` headers + a smaller binary; if it's unused legacy, remove it. Either way this is the single largest contributor to image size and to monthly base-image security drift.
- **Code**:
```dockerfile
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    tini \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
```
- **Fix**: Audit actual ffmpeg usage (`grep -r ffmpeg apps/server core`). If used for media thumbnails, switch to a static single-binary download or use a dedicated thumbnailer. If unused, drop the package — easy 200-400MB reduction.
- **Effort**: small

### Finding 8: `version` job tags HEAD before lint-test artifacts are reproducible, leaving orphan tags on transient build failures
- **File**: .github/workflows/release.yml:94-169
- **Severity**: medium
- **Description**: The retry comment at line 110 admits this: "If a build later fails the orphan tag is left in place; the next release auto-bumps past it." This means every flake in `build-windows`, `build-ios`, `build-android` consumes a real version number permanently. With macOS/Windows/iOS runners' baseline flake rate, the patch number drifts upward without correlation to actual shipped releases — bad for changelogs, semver consumers, and watchtower (which tags on `v*` patterns). Worse, the GHCR images for `version` (the `docker` job runs after `version` succeeds) may already be pushed with the reserved tag *before* the iOS upload-to-TestFlight step fails, so an unreleased version exists in the registry pointed-to by `latest`.
- **Code**:
```yaml
# Idempotency: if a prior attempt of this same step already
# pushed the tag (e.g. step retry, runner restart), short-
# circuit to success rather than re-tagging and aborting.
```
- **Fix**: Move tag reservation to *after* all platform builds succeed (right before the `release` job creates the GitHub release). The version job can compute the *intended* version without pushing the tag; the final `release` job pushes the tag atomically with `softprops/action-gh-release`. Trade-off: lose the SHA-pinning across jobs, but builds become idempotent on retry and orphan tags disappear.
- **Effort**: medium

### Finding 9: Dev compose uses identical PG port (:5432) as host — `./scripts/run.sh` clashes with any local Postgres install
- **File**: infra/docker/docker-compose.yml:8-9
- **Severity**: low
- **Description**: Dev compose binds host `:5432` directly. Any developer with system PostgreSQL installed (Linux distros that auto-enable it, macOS Homebrew users) can't run `./scripts/run.sh` without first stopping their local pg. The test compose correctly avoids this with `:5433`. Onboarding friction; not a security issue.
- **Code**:
```yaml
ports:
  - "5432:5432"
```
- **Fix**: Bind to `127.0.0.1:5433:5432` to match the test compose convention and avoid host clash, or document the requirement loudly in the README. Update DATABASE_URL examples accordingly.
- **Effort**: small

### Finding 10: Flutter coverage threshold ratchet is one-way and currently 35% — well below industry "decent" floor
- **File**: .github/workflows/flutter-ci.yml:62-73
- **Severity**: low
- **Description**: Threshold was lowered from 41.2% to 35.0% on 2026-05-01 to unblock CI after PR #720 added 3.5kLoC of untested-on-line-basis features. There's no calendar/issue tracking the "raise it back" commitment. The pattern (lower-on-fail, never raise) is anti-ratchet — it converts a coverage gate into a ceiling. Combined with the fact that 764+ Flutter tests already exist, 35% means most of the new feature surface is not actually exercised. CLAUDE.md explicitly demands tests-after for features in `/echo-feat`; the gate is no longer enforcing that.
- **Code**:
```python
# Floor lowered to 35.0 to unblock CI; raise it back as
# coverage on the new surface area improves.
threshold = 35.0
```
- **Fix**: Add a scheduled job (or pre-commit script) that asserts current coverage >= last-recorded high-water mark + epsilon; refuse to lower the threshold without a tracking issue. Open an issue to walk the floor back to 41% with a 2-week deadline.
- **Effort**: small
