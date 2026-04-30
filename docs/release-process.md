# Release process

Echo's release workflow auto-increments the patch version when a tag matching
`v*` is pushed to `main`. The release pipeline (`.github/workflows/release.yml`)
then runs the security gate, builds artifacts for every platform (Linux
AppImage, Windows .exe, macOS, Android, iOS, Web, Server, Docker images), and
publishes a GitHub Release.

## Tag ruleset (audit #594)

The release pipeline's `version` job creates `v*` tags from `github-actions[bot]`
during the auto-increment step. Without a ruleset restricting who can push
those tags, any collaborator with write access can push a tag manually and
trigger an unintended release of arbitrary content.

The protection lives in GitHub's tag-ruleset UI, not in code. To configure:

1. **Repo → Settings → Rules → Rulesets → New ruleset**.
2. **Name**: `release-tags`.
3. **Enforcement**: `Active`.
4. **Target**: `Tags` → `Include by pattern` → `v*`.
5. **Bypass list**: add `Repository admin` and the GitHub Actions app
   (search for "Actions" — the bot ID for our auto-tag step). Verify by
   checking `release.yml`: the `version` job uses `github.token` which the
   actions bot wraps. With the actions app on the bypass list, the bot can
   still push tags during the release flow.
6. **Restrictions** (apply to everyone *not* on the bypass list):
   - `Restrict creations` — on
   - `Restrict updates` — on
   - `Restrict deletions` — on
   - `Block force pushes` — on (defense in depth, even though tags don't
     normally accept force pushes)
7. **Save**.

After saving, attempt to push a `v*` tag from a non-admin account to verify
the restriction takes effect. Successful release tags from
`github-actions[bot]` should continue to work.

## Operator runbook

Routine release (no operator action needed):

1. Merge a `dev` → `main` PR with the changes you want to ship.
2. The release workflow's `version` job auto-bumps the patch version,
   creates the tag, and triggers downstream artifact builds.

Hotfix:

1. Branch off `main` (not `dev`) for the fix.
2. PR to `main` with the conventional-commit subject prefixed `fix:`.
3. Merge — the auto-tagger handles the rest.

Manual force release (rare; e.g. re-running a failed release after
infra fix):

1. Repo admin pushes the tag manually from the bypass-listed account.
2. Document the reason in the GitHub Release notes.

## Related

- `.github/workflows/release.yml` — the pipeline this protects.
- Audit issue: #594.
- Security model: docs/SECURITY.md.
