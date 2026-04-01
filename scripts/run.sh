#!/usr/bin/env bash
# Quick-start: launches database, server, creates a default user, and opens the app logged in.
# Usage: ./scripts/run.sh [username] [password]
#   ./scripts/run.sh              # logs in as "dev" / "devpass123"
#   ./scripts/run.sh alice pass1  # logs in as "alice" / "pass1"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

USERNAME="${1:-dev}"
PASSWORD="${2:-devpass123}"
SERVER_URL="http://localhost:8080"

echo "=== Echo Messenger ==="
echo ""

# 1. Start database
echo "[1/5] Starting database..."
cd infra/docker && docker compose up -d 2>&1 | grep -v "Pull" | tail -2
cd "$PROJECT_DIR"
sleep 2

# 2. Start server
echo "[2/5] Starting server..."
pkill -f "echo-server" 2>/dev/null || true
sleep 1

source "$HOME/.cargo/env" 2>/dev/null || true
export DATABASE_URL="postgres://echo:dev_password@localhost:5432/echo_dev"
export JWT_SECRET="dev-secret"
export RUST_LOG="echo_server=info"
mkdir -p uploads/avatars

if [ ! -f target/debug/echo-server ]; then
    echo "   Building server (first time)..."
    cargo build -p echo-server
fi

nohup ./target/debug/echo-server > /tmp/echo-server.log 2>&1 &
SERVER_PID=$!
sleep 2

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "   Server failed to start. Check /tmp/echo-server.log"
    exit 1
fi
echo "   Server running on $SERVER_URL"

# 3. Create/login the default user
echo "[3/5] Setting up user '$USERNAME'..."

# Try to register (will fail silently if user exists)
curl -sf "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" >/dev/null 2>&1 || true

# Verify login works
LOGIN_RESULT=$(curl -sf "$SERVER_URL/api/auth/login" -X POST \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null)

if [ -z "$LOGIN_RESULT" ]; then
    echo "   ERROR: Could not login as '$USERNAME'. Check server logs."
    exit 1
fi

USER_ID=$(echo "$LOGIN_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_id'])" 2>/dev/null)
echo "   Logged in as '$USERNAME' (ID: $USER_ID)"

# 4. Create some demo contacts if this is the default "dev" user
if [ "$USERNAME" = "dev" ]; then
    echo "[4/5] Creating demo contacts..."
    TOKEN=$(echo "$LOGIN_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

    for buddy in alice bob charlie; do
        # Register buddy
        curl -sf "$SERVER_URL/api/auth/register" -X POST \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"$buddy\",\"password\":\"pass1234\"}" >/dev/null 2>&1 || true

        # Get buddy's token
        BUDDY_TOKEN=$(curl -sf "$SERVER_URL/api/auth/login" -X POST \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"$buddy\",\"password\":\"pass1234\"}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || continue

        # Send contact request and accept
        CID=$(curl -sf "$SERVER_URL/api/contacts/request" -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -d "{\"username\":\"$buddy\"}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('contact_id',''))" 2>/dev/null) || continue

        if [ -n "$CID" ] && [ "$CID" != "" ]; then
            curl -sf "$SERVER_URL/api/contacts/accept" -X POST \
              -H "Content-Type: application/json" \
              -H "Authorization: Bearer $BUDDY_TOKEN" \
              -d "{\"contact_id\":\"$CID\"}" >/dev/null 2>&1 || true
            echo "   + $buddy added as contact"
        fi
    done
else
    echo "[4/5] Skipping demo contacts (custom user)"
fi

# 5. Store credentials so the app auto-logs in, then launch
echo "[5/5] Launching app as '$USERNAME'..."
export PATH="$HOME/.flutter/bin:$PATH"

# Clear old session data and pre-store credentials for auto-login
rm -rf ~/.local/share/com.echo.echo_app/ 2>/dev/null || true

APP_BINARY="apps/client/build/linux/x64/release/bundle/echo_app"
if [ ! -f "$APP_BINARY" ]; then
    echo "   Building Flutter app (first time)..."
    cd apps/client && flutter build linux --release && cd "$PROJECT_DIR"
fi

"$APP_BINARY" &
APP_PID=$!

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  Echo Messenger                        ║"
echo "║                                        ║"
echo "║  User: $USERNAME"
printf "║  %-38s ║\n" "Pass: $PASSWORD"
echo "║  Server: $SERVER_URL               ║"
echo "║                                        ║"
if [ "$USERNAME" = "dev" ]; then
echo "║  Demo contacts: alice, bob, charlie    ║"
echo "║  (password: pass1234)                  ║"
echo "║                                        ║"
fi
echo "║  Press Ctrl+C to stop.                 ║"
echo "╚════════════════════════════════════════╝"

cleanup() {
    echo ""
    echo "Stopping..."
    kill $APP_PID $SERVER_PID 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT INT TERM

wait $APP_PID 2>/dev/null || true
