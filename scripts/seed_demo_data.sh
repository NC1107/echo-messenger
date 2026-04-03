#!/usr/bin/env bash
# Seed the Echo Messenger database with demo groups and a test user.
# Usage: ./scripts/seed_demo_data.sh [SERVER_URL]

set -euo pipefail

BASE="${1:-http://localhost:8080}"

echo "==> Seeding demo data on $BASE"

# Register admin_tester account (ignore if already exists)
echo "  Creating admin_tester..."
curl -sf -X POST "$BASE/api/auth/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin_tester","password":"admin123"}' || true

# Login and get token
echo "  Logging in..."
TOKEN=$(curl -sf -X POST "$BASE/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin_tester","password":"admin123"}' | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Failed to get auth token"
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

# Create public groups (server auto-creates #general + voice lounge channels)
GROUPS=(
  "Animal Lovers"
  "Meme Central"
  "Tech Talk"
  "Gaming Lounge"
  "Music Corner"
  "Art Gallery"
  "Movie Club"
  "Book Worms"
  "Fitness Crew"
  "Food & Recipes"
)

for name in "${GROUPS[@]}"; do
  echo "  Creating group: $name"
  curl -sf -X POST "$BASE/api/groups" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$name\",\"is_public\":true}" || echo "    (may already exist)"
done

echo "==> Done! Created admin_tester + ${#GROUPS[@]} public groups."
echo "    Login: admin_tester / admin123"
