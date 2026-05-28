#!/usr/bin/env bash
# scripts/seed_check.sh — smoke wrapper for the Echo Messenger v2 seed scripts.
#
# Ensures Postgres is up (starts it if not), waits for the server, then runs
# seed_realistic_day.sh and seed_dms_only.sh end-to-end.  Exits non-zero on
# any failure and prints final DB row counts.
#
# Usage:
#   SEED_SERVER=http://localhost:8080 ./scripts/seed_check.sh
#
# Environment variables (all optional):
#   SEED_SERVER           Echo server base URL (default http://localhost:8080)
#   SEED_REGISTER_PAUSE   Seconds between user registrations (default 0 for localhost)
#   SKIP_POSTGRES_START   Set to 1 to skip the docker compose up step
#   DATABASE_URL          Postgres connection string for row-count queries
#                         (default postgres://echo:test_password@localhost:5432/echo_dev)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_SERVER="${SEED_SERVER:-http://localhost:8080}"
DATABASE_URL="${DATABASE_URL:-postgres://echo:test_password@localhost:5432/echo_dev}"
SKIP_POSTGRES_START="${SKIP_POSTGRES_START:-0}"
# Localhost seeding doesn't need the inter-registration pause.
export SEED_REGISTER_PAUSE="${SEED_REGISTER_PAUSE:-0}"
export SEED_SERVER

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_info()  { printf '\033[36m[check]\033[0m %s\n' "$*" >&2; }
_ok()    { printf '\033[32m[ok]\033[0m    %s\n' "$*" >&2; }
_fail()  { printf '\033[31m[FAIL]\033[0m  %s\n' "$*" >&2; }
_die()   { _fail "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Postgres
# ---------------------------------------------------------------------------
if [ "$SKIP_POSTGRES_START" != "1" ]; then
  _info "ensuring PostgreSQL is up (docker compose)"
  INFRA_DIR="$(dirname "$SCRIPT_DIR")/infra/docker"
  if [ -f "$INFRA_DIR/docker-compose.yml" ]; then
    docker compose -f "$INFRA_DIR/docker-compose.yml" up -d 2>&1 | tail -3
  else
    _info "infra/docker/docker-compose.yml not found; assuming Postgres is already running"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Server health — wait up to 60s
# ---------------------------------------------------------------------------
_info "waiting for server at $SEED_SERVER"
TRIES=0
until curl -sS "$SEED_SERVER/api/health" >/dev/null 2>&1; do
  TRIES=$((TRIES + 1))
  if [ $TRIES -ge 60 ]; then
    _die "server did not become healthy after 60s — is it running?"
  fi
  sleep 1
done
_ok "server is up"

# ---------------------------------------------------------------------------
# 3. Run seed scripts
# ---------------------------------------------------------------------------
_info "running seed_realistic_day.sh"
if ! bash "$SCRIPT_DIR/seed_realistic_day.sh" 2>&1; then
  _fail "seed_realistic_day.sh exited non-zero"
  exit 1
fi
_ok "seed_realistic_day.sh complete"

_info "running seed_dms_only.sh"
if ! bash "$SCRIPT_DIR/seed_dms_only.sh" 2>&1; then
  _fail "seed_dms_only.sh exited non-zero"
  exit 1
fi
_ok "seed_dms_only.sh complete"

# ---------------------------------------------------------------------------
# 4. Row counts
# ---------------------------------------------------------------------------
_info "querying row counts"
if command -v psql >/dev/null 2>&1; then
  psql "$DATABASE_URL" -c "
    SELECT
      (SELECT count(*) FROM users)          AS users,
      (SELECT count(*) FROM conversations)  AS conversations,
      (SELECT count(*) FROM messages
       WHERE deleted_at IS NULL)            AS messages,
      (SELECT count(*) FROM group_members)  AS group_members;
  " 2>&1 || _info "(psql query failed — counts unavailable)"
else
  _info "psql not found; skipping row counts"
fi

_ok "seed_check complete"
