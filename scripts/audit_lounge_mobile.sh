#!/usr/bin/env bash
# scripts/audit_lounge_mobile.sh — entry point for the voice-lounge mobile audit.
#
# Origin: user feedback 2026-05-28 ("not seeing good results on mobile /
# vertical canvas" in the lounge). The audit spec walks the lounge UI at
# iPhone-ish 390x844 (then 844x390), screenshots every state, runs soft
# bounding-box / tap-target assertions, and writes a markdown report
# at tests/e2e/output/mobile-audit-report.md.
#
# This wrapper exists so the audit is one command from a clean shell:
#   ./scripts/audit_lounge_mobile.sh
#
# Prerequisites
# -------------
#  - Docker (Postgres comes up via scripts/seed_check.sh).
#  - Local Echo server already started OR start it manually beforehand —
#    seed_check.sh waits for it but does NOT start cargo.
#  - Flutter web build served at $ECHO_URL (default http://localhost:8081).
#
# Override the target with ECHO_SERVER / ECHO_URL env vars (matches the
# convention used by tests/e2e/harness/two-client.ts).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ECHO_SERVER="${ECHO_SERVER:-http://localhost:8080}"
ECHO_URL="${ECHO_URL:-http://localhost:8081}"

echo "[audit] target server=$ECHO_SERVER  web=$ECHO_URL"

# Bring up Postgres + seed users. seed_check.sh is idempotent and waits for
# the server to respond before returning; if the server isn't running this
# call will hang on the wait — that's the operator's signal to start it.
if [ -x "$REPO_ROOT/scripts/seed_check.sh" ]; then
  echo "[audit] seeding via seed_check.sh"
  SEED_SERVER="$ECHO_SERVER" "$REPO_ROOT/scripts/seed_check.sh" || {
    echo "[audit] seed_check.sh failed — continuing anyway (audit registers its own users)" >&2
  }
else
  echo "[audit] scripts/seed_check.sh not found — skipping seed step" >&2
fi

cd "$REPO_ROOT/tests/e2e"

echo "[audit] running mobile lounge audit"
ECHO_SERVER="$ECHO_SERVER" ECHO_URL="$ECHO_URL" \
  npx playwright test voice_lounge_mobile_audit.spec.ts --project=maintained

REPORT="$REPO_ROOT/tests/e2e/output/mobile-audit-report.md"
if [ -f "$REPORT" ]; then
  echo "[audit] report: $REPORT"
else
  echo "[audit] expected report not produced at $REPORT" >&2
  exit 1
fi
