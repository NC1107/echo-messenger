#!/usr/bin/env bash
# scripts/audit_lounge_deep.sh -- deep mobile-canvas audit runner.
#
# Boots Postgres + the dev server (via seed_check.sh), then runs the
# voice_lounge_mobile_audit.spec.ts across iPhone 12, Pixel 5, and iPad
# Pro 11 (portrait + landscape each) and prints the report path.
#
# Designed to be the canonical mobile-canvas smoke test -- every PR that
# touches lounge gesture / drawing code should run this locally before
# requesting review.
#
# Usage:
#   ./scripts/audit_lounge_deep.sh
#
# Optional env:
#   ECHO_SERVER   API base URL (default http://localhost:8080)
#   ECHO_URL      Web base URL (default http://localhost:8081)
#   SKIP_SEED     Set to 1 to skip seed_check.sh (assumes server is up)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
E2E_DIR="$ROOT_DIR/tests/e2e"
OUTPUT_DIR="$E2E_DIR/output"
REPORT_PATH="$OUTPUT_DIR/mobile-audit-report.md"

ECHO_SERVER="${ECHO_SERVER:-http://localhost:8080}"
ECHO_URL="${ECHO_URL:-http://localhost:8081}"
SKIP_SEED="${SKIP_SEED:-0}"

_info() { printf '\033[36m[audit]\033[0m %s\n' "$*" >&2; }
_ok()   { printf '\033[32m[ok]\033[0m    %s\n' "$*" >&2; }
_fail() { printf '\033[31m[FAIL]\033[0m  %s\n' "$*" >&2; }

# Ensure the dev server is up. seed_check.sh starts Postgres + waits for
# the server's /api/health, then seeds fixtures. We tolerate a non-zero
# exit from seed_check.sh (e.g. seed user collision) as long as
# /api/health responds, because the audit itself registers its own users.
if [ "$SKIP_SEED" != "1" ]; then
  _info "running seed_check.sh (starts PG + waits for server)"
  bash "$SCRIPT_DIR/seed_check.sh" || _info "seed_check.sh exited non-zero (continuing if /health is up)"
else
  _info "SKIP_SEED=1 -- not running seed_check.sh"
fi

_info "verifying server health at $ECHO_SERVER"
if ! curl -sS "$ECHO_SERVER/api/health" >/dev/null 2>&1; then
  _fail "server did not respond at $ECHO_SERVER/api/health -- start it via ./scripts/run.sh and retry"
  exit 1
fi
_ok "server is up"

# Web server: the spec drives APP_URL = ECHO_URL/?server=ECHO_SERVER. We
# expect a Flutter web build served on :8081. If the user hasn't started
# one, surface that clearly rather than letting Playwright time out.
_info "verifying web build at $ECHO_URL"
if ! curl -sS -o /dev/null -w '%{http_code}' "$ECHO_URL/" | grep -qE '^(200|302)$'; then
  _fail "web build not reachable at $ECHO_URL -- run 'cd apps/client && flutter build web && cd build/web && python3 -m http.server 8081'"
  exit 1
fi
_ok "web build is up"

# Ensure Playwright is installed in the e2e package.
if [ ! -d "$E2E_DIR/node_modules/@playwright" ]; then
  _info "installing Playwright (one-off)"
  (cd "$E2E_DIR" && npm install --no-fund --no-audit)
fi

mkdir -p "$OUTPUT_DIR"

_info "running deep audit -- this exercises 3 devices x 2 orientations and"
_info "takes ~10-20 minutes on first run (videos + traces enabled)"
cd "$E2E_DIR"
ECHO_SERVER="$ECHO_SERVER" ECHO_URL="$ECHO_URL" \
  npx playwright test \
  --config="$E2E_DIR/playwright.audit.config.ts" \
  --project=deep-audit \
  voice_lounge_mobile_audit.spec.ts \
  || _info "audit spec exited non-zero (this is expected when soft checks fail -- see report)"

if [ -f "$REPORT_PATH" ]; then
  _ok "report written: $REPORT_PATH"
  echo
  head -50 "$REPORT_PATH"
  echo
  _ok "screenshots: $OUTPUT_DIR/screenshots/"
  _ok "videos:      $OUTPUT_DIR/videos/"
  _ok "html report: $OUTPUT_DIR/html-report/index.html"
else
  _fail "no report produced -- the spec may have crashed before any test ran"
  exit 1
fi
