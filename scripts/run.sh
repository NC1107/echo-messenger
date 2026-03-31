#!/usr/bin/env bash
# Quick-start: launches database, server, and the Flutter app.
# Usage: ./scripts/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

echo "=== Echo Messenger ==="

# 1. Start database
echo "[1/3] Starting database..."
cd infra/docker && docker compose up -d 2>&1 | grep -v "Pull" | tail -2
cd "$PROJECT_DIR"
sleep 2

# 2. Start server
echo "[2/3] Starting server..."
pkill -f "echo-server" 2>/dev/null || true
sleep 1

source "$HOME/.cargo/env" 2>/dev/null || true
export DATABASE_URL="postgres://echo:dev_password@localhost:5432/echo_dev"
export JWT_SECRET="dev-secret"
export RUST_LOG="echo_server=info"

# Build if needed
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
echo "   Server running (PID $SERVER_PID) on http://localhost:8080"

# 3. Launch app
echo "[3/3] Launching app..."
export PATH="$HOME/.flutter/bin:$PATH"

APP_BINARY="apps/client/build/linux/x64/release/bundle/echo_app"
if [ ! -f "$APP_BINARY" ]; then
    echo "   Building Flutter app (first time)..."
    cd apps/client && flutter build linux --release && cd "$PROJECT_DIR"
fi

"$APP_BINARY" &
APP_PID=$!

echo ""
echo "=== Running ==="
echo "Server: http://localhost:8080 (PID $SERVER_PID)"
echo "App:    PID $APP_PID"
echo "Logs:   /tmp/echo-server.log"
echo ""
echo "Press Ctrl+C to stop."

cleanup() {
    echo ""
    echo "Stopping..."
    kill $APP_PID $SERVER_PID 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT INT TERM

wait $APP_PID 2>/dev/null || true
