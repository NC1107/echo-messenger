#!/usr/bin/env bash
# Seed the Echo Messenger database with demo groups and a test user.
# Usage: ./scripts/seed_demo_data.sh [SERVER_URL]

set -euo pipefail

BASE="${1:-http://localhost:8080}"

echo "==> Seeding demo data on $BASE"

# Register admin_tester account (ignore if already exists)
echo "  Creating admin_tester..."
curl -sS -X POST "$BASE/api/auth/register" \
  -H "Content-Type: application/json" \
  -H "User-Agent: Mozilla/5.0 echo-seed" \
  -d '{"username":"admin_tester","password":"admin123"}' > /dev/null || true

# Login and get token
echo "  Logging in..."
LOGIN=$(curl -sS -X POST "$BASE/api/auth/login" \
  -H "Content-Type: application/json" \
  -H "User-Agent: Mozilla/5.0 echo-seed" \
  -d '{"username":"admin_tester","password":"admin123"}')
TOKEN=$(echo "$LOGIN" | jq -r '.access_token // empty')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Failed to get auth token. Response: $LOGIN"
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

# Create public groups with descriptions.
# Field is `name` (not `title`) per the CreateGroupRequest schema.
unset GROUPS
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

for gname in "${!GROUPS[@]}"; do
  desc="${GROUPS[$gname]}"
  echo "  Creating group: $gname"
  BODY=$(jq -nc --arg n "$gname" --arg d "$desc" \
    '{name:$n, description:$d, is_public:true, is_encrypted:false}')
  RESP=$(curl -sS -X POST "$BASE/api/groups" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -H "User-Agent: Mozilla/5.0 echo-seed" \
    -d "$BODY")
  GROUP_ID=$(echo "$RESP" | jq -r '.id // empty')
  if [ -z "$GROUP_ID" ]; then
    ERR=$(echo "$RESP" | jq -r '.error // .code // "unknown"' 2>/dev/null || echo "unknown")
    echo "    (group may already exist or errored: $ERR)"
  fi
done

echo ""
echo "==> Done! Created admin_tester + ${#GROUPS[@]} public groups."
echo "    Login: admin_tester / admin123"
