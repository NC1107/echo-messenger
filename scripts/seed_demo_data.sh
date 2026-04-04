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
LOGIN=$(curl -sf -X POST "$BASE/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin_tester","password":"admin123"}')
TOKEN=$(echo "$LOGIN" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "$LOGIN" | jq -r '.token' 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Failed to get auth token"
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

# Create public groups with descriptions
declare -A GROUPS
GROUPS=(
  ["Tech Talk"]="Discuss the latest in technology, programming, and gadgets"
  ["Gaming Lounge"]="LFG, game reviews, and esports discussion"
  ["Music Corner"]="Share tracks, discover new artists, and talk music theory"
  ["Art & Design"]="Showcase your art, get feedback, and share inspiration"
  ["Random Chat"]="Off-topic conversations, memes, and general hangout"
  ["Movie Club"]="Movie recommendations, reviews, and watch parties"
  ["Book Worms"]="Book reviews, reading lists, and literary discussion"
  ["Fitness Crew"]="Workout tips, progress tracking, and motivation"
  ["Food & Recipes"]="Share recipes, restaurant finds, and cooking tips"
  ["Meme Central"]="The finest memes, curated by the community"
)

for name in "${!GROUPS[@]}"; do
  desc="${GROUPS[$name]}"
  echo "  Creating group: $name"
  curl -sf -X POST "$BASE/api/groups" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$name\",\"description\":\"$desc\",\"is_public\":true}" || echo "    (may already exist)"
done

echo ""
echo "==> Done! Created admin_tester + ${#GROUPS[@]} public groups."
echo "    Login: admin_tester / admin123"
