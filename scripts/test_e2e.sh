#!/usr/bin/env bash
# Automated end-to-end test: verifies the full messaging pipeline.
# Tests registration, contacts, WebSocket messaging, and offline delivery.
# Usage: ./scripts/test_e2e.sh
set -euo pipefail

SERVER_URL="http://localhost:8080"
PASS=0
FAIL=0
TOTAL=0

green() { echo -e "\033[32m✓ $1\033[0m"; }
red()   { echo -e "\033[31m✗ $1\033[0m"; }

assert_eq() {
    TOTAL=$((TOTAL + 1))
    if [ "$1" = "$2" ]; then
        green "$3"
        PASS=$((PASS + 1))
    else
        red "$3 (expected '$2', got '$1')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    TOTAL=$((TOTAL + 1))
    if echo "$1" | grep -q "$2"; then
        green "$3"
        PASS=$((PASS + 1))
    else
        red "$3 (expected to contain '$2', got '$1')"
        FAIL=$((FAIL + 1))
    fi
}

assert_status() {
    TOTAL=$((TOTAL + 1))
    local status=$1 expected=$2 desc=$3
    if [ "$status" -eq "$expected" ]; then
        green "$desc (HTTP $status)"
        PASS=$((PASS + 1))
    else
        red "$desc (expected HTTP $expected, got HTTP $status)"
        FAIL=$((FAIL + 1))
    fi
}

echo "╔═══════════════════════════════════════╗"
echo "║     Echo E2E Test Suite               ║"
echo "╚═══════════════════════════════════════╝"
echo ""

# ─── Auth Tests ───

echo "── Auth ──"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" -d '{"username":"test_alice","password":"password123"}')
assert_status "$STATUS" 201 "Register alice"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" -d '{"username":"test_bob","password":"password456"}')
assert_status "$STATUS" 201 "Register bob"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" -d '{"username":"test_alice","password":"password123"}')
assert_status "$STATUS" 409 "Duplicate registration rejected"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
assert_status "$STATUS" 400 "Short username rejected"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/api/auth/register" -X POST \
  -H "Content-Type: application/json" -d '{"username":"validuser","password":"short"}')
assert_status "$STATUS" 400 "Short password rejected"

ALICE=$(curl -s "$SERVER_URL/api/auth/login" -X POST \
  -H "Content-Type: application/json" -d '{"username":"test_alice","password":"password123"}')
assert_contains "$ALICE" "access_token" "Login alice returns token"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/api/auth/login" -X POST \
  -H "Content-Type: application/json" -d '{"username":"test_alice","password":"wrong"}')
assert_status "$STATUS" 401 "Wrong password rejected"

ALICE_TOKEN=$(echo "$ALICE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
BOB=$(curl -s "$SERVER_URL/api/auth/login" -X POST \
  -H "Content-Type: application/json" -d '{"username":"test_bob","password":"password456"}')
BOB_TOKEN=$(echo "$BOB" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
BOB_ID=$(echo "$BOB" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_id'])")
ALICE_ID=$(echo "$ALICE" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_id'])")

# ─── Contact Tests ───

echo ""
echo "── Contacts ──"

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/api/contacts" \
  -H "Authorization: Bearer $ALICE_TOKEN")
assert_status "$STATUS" 200 "List contacts (empty)"

RESULT=$(curl -s "$SERVER_URL/api/contacts/request" -X POST \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ALICE_TOKEN" \
  -d '{"username":"test_bob"}')
assert_contains "$RESULT" "contact_id" "Alice sends request to bob"
CONTACT_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['contact_id'])")

PENDING=$(curl -s "$SERVER_URL/api/contacts/pending" -H "Authorization: Bearer $BOB_TOKEN")
assert_contains "$PENDING" "test_alice" "Bob sees pending from alice"

RESULT=$(curl -s "$SERVER_URL/api/contacts/accept" -X POST \
  -H "Content-Type: application/json" -H "Authorization: Bearer $BOB_TOKEN" \
  -d "{\"contact_id\":\"$CONTACT_ID\"}")
assert_contains "$RESULT" "accepted" "Bob accepts request"

CONTACTS=$(curl -s "$SERVER_URL/api/contacts" -H "Authorization: Bearer $ALICE_TOKEN")
assert_contains "$CONTACTS" "test_bob" "Alice sees bob in contacts"

CONTACTS=$(curl -s "$SERVER_URL/api/contacts" -H "Authorization: Bearer $BOB_TOKEN")
assert_contains "$CONTACTS" "test_alice" "Bob sees alice in contacts"

# ─── WebSocket Messaging Tests ───

echo ""
echo "── WebSocket Messaging ──"

source "$HOME/.cargo/env" 2>/dev/null || true

# Test: Send message while recipient is offline (offline delivery)
echo '{"type":"send_message","to_user_id":"'"$BOB_ID"'","content":"Hello from alice (offline)"}' \
  | timeout 3 websocat "ws://localhost:8080/ws?token=$ALICE_TOKEN" > /tmp/e2e_alice1.txt 2>&1 || true

assert_contains "$(cat /tmp/e2e_alice1.txt)" "message_sent" "Alice sends message (bob offline), gets confirmation"

# Bob connects and should receive the offline message
timeout 3 websocat "ws://localhost:8080/ws?token=$BOB_TOKEN" > /tmp/e2e_bob1.txt 2>&1 || true
assert_contains "$(cat /tmp/e2e_bob1.txt)" "Hello from alice" "Bob receives offline message on connect"
assert_contains "$(cat /tmp/e2e_bob1.txt)" "new_message" "Bob receives correct message type"

# Test: Real-time delivery (both online)
# Use a named pipe so Bob stays connected while Alice sends
rm -f /tmp/e2e_bob_fifo
mkfifo /tmp/e2e_bob_fifo

# Bob connects via named pipe (stays open)
cat /tmp/e2e_bob_fifo | timeout 8 websocat "ws://localhost:8080/ws?token=$BOB_TOKEN" > /tmp/e2e_bob2.txt 2>&1 &
BOB_WS=$!
sleep 2

# Alice sends while Bob is online
echo '{"type":"send_message","to_user_id":"'"$BOB_ID"'","content":"Real-time hello!"}' \
  | timeout 3 websocat "ws://localhost:8080/ws?token=$ALICE_TOKEN" > /tmp/e2e_alice2.txt 2>&1 || true
sleep 2

# Close Bob's input to let him finish
echo "" > /tmp/e2e_bob_fifo 2>/dev/null || true
wait $BOB_WS 2>/dev/null || true
rm -f /tmp/e2e_bob_fifo

assert_contains "$(cat /tmp/e2e_alice2.txt)" "message_sent" "Alice gets confirmation (real-time)"
assert_contains "$(cat /tmp/e2e_bob2.txt)" "Real-time hello" "Bob receives real-time message"

# Test: Non-contact messaging should fail
echo '{"type":"send_message","to_user_id":"00000000-0000-0000-0000-000000000000","content":"should fail"}' \
  | timeout 3 websocat "ws://localhost:8080/ws?token=$ALICE_TOKEN" > /tmp/e2e_alice3.txt 2>&1 || true
assert_contains "$(cat /tmp/e2e_alice3.txt)" "error" "Non-contact message rejected"

# ─── REST Message History ───

echo ""
echo "── Message History ──"

CONVOS=$(curl -s "$SERVER_URL/api/conversations" -H "Authorization: Bearer $ALICE_TOKEN")
assert_contains "$CONVOS" "conversation_id" "Alice can list conversations"

# ─── Summary ───

echo ""
echo "════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
