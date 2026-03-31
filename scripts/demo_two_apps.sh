#!/usr/bin/env bash
# Launch two Echo app instances side-by-side with pre-seeded accounts.
# Usage: ./scripts/demo_two_apps.sh
set -euo pipefail

SERVER_URL="http://localhost:8080"
WS_URL="ws://localhost:8080"
APP_BINARY="apps/client/build/linux/x64/release/bundle/echo_app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Echo Messaging Demo ==="
echo ""

# Check prerequisites
command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
test -f "$APP_BINARY" || { echo "ERROR: Flutter app not built. Run: cd apps/client && flutter build linux"; exit 1; }

# Start/reset database
echo "[1/6] Starting database..."
cd infra/docker && docker compose up -d 2>&1 | grep -v "Pull" | tail -2
cd "$PROJECT_DIR"
sleep 2

# Reset database
echo "[2/6] Resetting database..."
docker exec docker-postgres-1 psql -U echo -d echo_dev -c \
  "DROP TABLE IF EXISTS messages, conversation_members, conversations, contacts, users CASCADE;" \
  >/dev/null 2>&1

# Kill any existing server
pkill -f "echo-server" 2>/dev/null || true
sleep 1

# Start server
echo "[3/6] Starting server..."
source "$HOME/.cargo/env" 2>/dev/null || true
DATABASE_URL="postgres://echo:dev_password@localhost:5432/echo_dev" \
JWT_SECRET="dev-secret" \
RUST_LOG="echo_server=info" \
"$PROJECT_DIR/target/debug/echo-server" &
SERVER_PID=$!
sleep 2

# Check server is running
curl -sf "$SERVER_URL/api/auth/login" -X POST -H "Content-Type: application/json" \
  -d '{"username":"_","password":"_"}' >/dev/null 2>&1 || true
echo "   Server running (PID $SERVER_PID)"

# Pre-seed accounts
echo "[4/6] Creating test accounts..."
ALICE=$(curl -sf "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","password":"password123"}')
BOB=$(curl -sf "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"bob","password":"password456"}')

ALICE_TOKEN=$(echo "$ALICE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
BOB_TOKEN=$(echo "$BOB" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "   alice registered"
echo "   bob registered"

# Make them contacts
echo "[5/6] Setting up contacts..."
CONTACT=$(curl -sf "$SERVER_URL/api/contacts/request" -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ALICE_TOKEN" \
  -d '{"username":"bob"}')
CONTACT_ID=$(echo "$CONTACT" | python3 -c "import sys,json; print(json.load(sys.stdin)['contact_id'])")

curl -sf "$SERVER_URL/api/contacts/accept" -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $BOB_TOKEN" \
  -d "{\"contact_id\":\"$CONTACT_ID\"}" >/dev/null

echo "   alice <-> bob are contacts"

# Launch two app instances
echo "[6/6] Launching two app instances..."
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  Login as 'alice' (password: password123) ║"
echo "  ║  in one window, and 'bob' (password456)   ║"
echo "  ║  in the other. Then open a chat!          ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# Launch first app
"$APP_BINARY" &
APP1_PID=$!

# Slight offset so windows don't overlap perfectly
sleep 1

# Launch second app
"$APP_BINARY" &
APP2_PID=$!

echo "App 1 PID: $APP1_PID"
echo "App 2 PID: $APP2_PID"
echo ""
echo "Press Ctrl+C to stop everything."

# Cleanup on exit
cleanup() {
    echo ""
    echo "Shutting down..."
    kill $APP1_PID $APP2_PID $SERVER_PID 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT INT TERM

# Wait for apps to exit
wait $APP1_PID $APP2_PID 2>/dev/null || true
