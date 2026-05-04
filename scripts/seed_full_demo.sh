#!/usr/bin/env bash
# Seed Echo Messenger with realistic, themed test data using only the public
# REST + WebSocket API. Works against any reachable server -- localhost,
# staging, production, anywhere -- with no DB credentials needed.
#
# What gets seeded (driven by scripts/seed_assets/demo.json):
#   - Users with profile bios + status messages
#   - All-to-all accepted contacts
#   - Public groups with thematic descriptions and member lists
#   - Real-world themed messages, with replies and pins
#   - Reactions on messages
#
# Usage:
#   ./scripts/seed_full_demo.sh                                    # localhost
#   SERVER_URL=https://staging.echo-messenger.us ./scripts/seed_full_demo.sh
#   DATA_FILE=scripts/seed_assets/my_scenario.json ./scripts/seed_full_demo.sh
#
# Env:
#   SERVER_URL  Echo server base URL (default http://localhost:8080)
#   DATA_FILE   Path to seed JSON  (default scripts/seed_assets/demo.json)
#   PASSWORD    Override the password from the JSON file
#   VERBOSE     1 to dump every API request/response
#
# Dependencies: curl, jq, websocat. Install websocat with `cargo install websocat`
# or grab a static binary from https://github.com/vi/websocat/releases.
#
# Reruns are idempotent: existing users login instead of registering, contacts
# upsert, and groups skip if a same-named public group already exists for the
# owner. Messages are always appended -- the timeline grows on each rerun.

set -euo pipefail

SERVER_URL="${SERVER_URL:-http://localhost:8080}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FILE="${DATA_FILE:-$SCRIPT_DIR/seed_assets/demo.json}"
VERBOSE="${VERBOSE:-0}"

# ----- Dependency checks ----------------------------------------------------
for cmd in curl jq websocat; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but not on PATH" >&2
    [ "$cmd" = "websocat" ] && \
      echo "       install: cargo install websocat  (or download from github.com/vi/websocat/releases)" >&2
    exit 1
  fi
done

if [ ! -f "$DATA_FILE" ]; then
  echo "ERROR: data file not found: $DATA_FILE" >&2
  exit 1
fi

if ! jq -e . "$DATA_FILE" >/dev/null 2>&1; then
  echo "ERROR: $DATA_FILE is not valid JSON" >&2
  exit 1
fi

PASSWORD="${PASSWORD:-$(jq -r '.password' "$DATA_FILE")}"
WS_BASE="$(echo "$SERVER_URL" | sed -e 's|^http://|ws://|' -e 's|^https://|wss://|')"

# ----- Logging --------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
vlog() { [ "$VERBOSE" = "1" ] && printf '   [v] %s\n' "$*" >&2 || true; }

# ----- Server reachability --------------------------------------------------
log "==> Echo seed"
log "    server : $SERVER_URL"
log "    data   : $DATA_FILE"
if ! curl -sf -m 5 "$SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "ERROR: server not reachable at $SERVER_URL/api/health" >&2
  exit 1
fi

# ----- Helpers --------------------------------------------------------------
api() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(-sS -X "$method" "$SERVER_URL$path" -H 'Content-Type: application/json')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ]  && args+=(-d "$body")
  vlog "$method $path"
  curl "${args[@]}"
}

# ----- Phase 1: users -------------------------------------------------------
log "==> Phase 1: users"
declare -A USER_ID
declare -A USER_TOKEN
USERS=()
while read -r u; do USERS+=("$u"); done < <(jq -r '.users[].username' "$DATA_FILE")

for u in "${USERS[@]}"; do
  resp=$(api POST /api/auth/register "" "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}")
  if [ "$(jq -r '.access_token // empty' <<<"$resp")" = "" ]; then
    resp=$(api POST /api/auth/login "" "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}")
  fi
  uid=$(jq -r '.user_id' <<<"$resp")
  tok=$(jq -r '.access_token' <<<"$resp")
  if [ "$uid" = "null" ] || [ -z "$uid" ]; then
    echo "ERROR: register/login failed for $u: $resp" >&2; exit 1
  fi
  USER_ID[$u]="$uid"
  USER_TOKEN[$u]="$tok"
  printf "    user %-8s %s\n" "$u" "$uid"
done

# Update profile (bio + status) for each user.
log "==> Phase 1b: profiles"
for u in "${USERS[@]}"; do
  bio=$(jq -r --arg u "$u" '.users[]|select(.username==$u).bio // empty' "$DATA_FILE")
  status=$(jq -r --arg u "$u" '.users[]|select(.username==$u).status_message // empty' "$DATA_FILE")
  body=$(jq -nc --arg b "$bio" --arg s "$status" '{bio:$b, status_message:$s}')
  api PATCH /api/users/me/profile "${USER_TOKEN[$u]}" "$body" >/dev/null
done

# ----- Phase 2: all-to-all contacts -----------------------------------------
log "==> Phase 2: contacts (all-to-all)"
for a in "${USERS[@]}"; do
  for b in "${USERS[@]}"; do
    [ "$a" = "$b" ] && continue
    req=$(api POST /api/contacts/request "${USER_TOKEN[$a]}" "{\"username\":\"$b\"}")
    contact_id=$(jq -r '.contact_id // .id // empty' <<<"$req")
    [ -z "$contact_id" ] && continue   # already contacts (request rejected)
    api POST /api/contacts/accept "${USER_TOKEN[$b]}" "{\"contact_id\":\"$contact_id\"}" >/dev/null || true
  done
done

# ----- Phase 3: groups ------------------------------------------------------
log "==> Phase 3: groups"
declare -A GROUP_ID
group_count=$(jq '.groups | length' "$DATA_FILE")
for i in $(seq 0 $((group_count - 1))); do
  name=$(jq -r ".groups[$i].name" "$DATA_FILE")
  desc=$(jq -r ".groups[$i].description" "$DATA_FILE")
  owner=$(jq -r ".groups[$i].owner" "$DATA_FILE")

  members=()
  while read -r m; do
    [ "$m" = "$owner" ] && continue
    members+=("\"${USER_ID[$m]}\"")
  done < <(jq -r ".groups[$i].members[]" "$DATA_FILE")
  members_json="[$(IFS=,; echo "${members[*]}")]"

  body=$(jq -nc \
    --arg name "$name" \
    --arg desc "$desc" \
    --argjson members "$members_json" \
    '{name:$name, description:$desc, is_public:true, member_ids:$members}')
  resp=$(api POST /api/groups "${USER_TOKEN[$owner]}" "$body")
  gid=$(jq -r '.id // empty' <<<"$resp")
  if [ -z "$gid" ]; then
    # Fallback: search public groups by name (idempotent rerun path).
    enc_name=$(jq -rn --arg n "$name" '$n|@uri')
    existing=$(api GET "/api/groups/public?search=$enc_name" "${USER_TOKEN[$owner]}")
    gid=$(jq -r --arg n "$name" '.[]|select(.title==$n)|.id' <<<"$existing" | head -1)
  fi
  if [ -z "$gid" ] || [ "$gid" = "null" ]; then
    echo "WARN: could not resolve group id for '$name': $resp" >&2
    continue
  fi
  GROUP_ID["$name"]="$gid"
  printf "    group %-16s %s\n" "$name" "$gid"
done

# ----- Phase 4: messages over WS, capture in-order ids via /messages fetch --
log "==> Phase 4: messages, replies, reactions, pins"
total_msgs=0
total_replies=0
total_reactions=0
total_pins=0

# Send a single WS payload as $1=user_token, $2=NDJSON line. Returns once
# the server has had a moment to ingest the frame.
ws_send_one() {
  local token="$1" payload="$2"
  local ticket
  ticket=$(api POST /api/auth/ws-ticket "$token" '' | jq -r '.ticket // empty')
  if [ -z "$ticket" ]; then
    echo "WARN: failed to mint WS ticket; skipping send" >&2
    return 1
  fi
  # `--no-close` keeps the socket open after stdin EOF so the server can
  # actually process the frame; we kill the client after a short wait.
  printf '%s' "$payload" \
    | websocat --no-close -E "$WS_BASE/ws?ticket=$ticket" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.5
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

for i in $(seq 0 $((group_count - 1))); do
  name=$(jq -r ".groups[$i].name" "$DATA_FILE")
  owner=$(jq -r ".groups[$i].owner" "$DATA_FILE")
  cid="${GROUP_ID[$name]:-}"
  [ -z "$cid" ] && continue

  msg_count=$(jq ".groups[$i].messages | length" "$DATA_FILE")

  # Send each message as the listed sender.
  for j in $(seq 0 $((msg_count - 1))); do
    sender=$(jq -r ".groups[$i].messages[$j].from" "$DATA_FILE")
    text=$(jq -r ".groups[$i].messages[$j].text" "$DATA_FILE")
    payload=$(jq -nc --arg cid "$cid" --arg t "$text" \
      '{type:"send_message", conversation_id:$cid, content:$t}')
    ws_send_one "${USER_TOKEN[$sender]}" "$payload" || true
    total_msgs=$((total_msgs + 1))
  done

  # Pull message IDs in chronological order.
  msgs_resp=$(api GET "/api/conversations/$cid/messages?limit=200" "${USER_TOKEN[$owner]}")
  mapfile -t MSG_IDS < <(jq -r '.[].id' <<<"$msgs_resp" | tac)

  # Replies: we resolve the parent id from the just-captured array.
  reply_count=$(jq ".groups[$i].replies | length // 0" "$DATA_FILE")
  for r in $(seq 0 $((reply_count - 1))); do
    [ "$reply_count" -eq 0 ] && break
    rfrom=$(jq -r ".groups[$i].replies[$r].from" "$DATA_FILE")
    rto=$(jq -r ".groups[$i].replies[$r].to_index" "$DATA_FILE")
    rtext=$(jq -r ".groups[$i].replies[$r].text" "$DATA_FILE")
    parent_id="${MSG_IDS[$rto]:-}"
    [ -z "$parent_id" ] && continue
    payload=$(jq -nc --arg cid "$cid" --arg t "$rtext" --arg p "$parent_id" \
      '{type:"send_message", conversation_id:$cid, content:$t, reply_to_id:$p}')
    ws_send_one "${USER_TOKEN[$rfrom]}" "$payload" || true
    total_replies=$((total_replies + 1))
  done

  # Reactions (REST, idempotent on duplicate emoji).
  rx_count=$(jq ".groups[$i].reactions | length // 0" "$DATA_FILE")
  for r in $(seq 0 $((rx_count - 1))); do
    [ "$rx_count" -eq 0 ] && break
    rfrom=$(jq -r ".groups[$i].reactions[$r].from" "$DATA_FILE")
    ridx=$(jq -r ".groups[$i].reactions[$r].message_index" "$DATA_FILE")
    remoji=$(jq -r ".groups[$i].reactions[$r].emoji" "$DATA_FILE")
    target_id="${MSG_IDS[$ridx]:-}"
    [ -z "$target_id" ] && continue
    body=$(jq -nc --arg e "$remoji" '{emoji:$e}')
    api POST "/api/messages/$target_id/reactions" "${USER_TOKEN[$rfrom]}" "$body" >/dev/null || true
    total_reactions=$((total_reactions + 1))
  done

  # Pin (REST).
  pin_idx=$(jq -r ".groups[$i].pin_index // empty" "$DATA_FILE")
  pinned=0
  if [ -n "$pin_idx" ] && [ "$pin_idx" != "null" ]; then
    pin_id="${MSG_IDS[$pin_idx]:-}"
    if [ -n "$pin_id" ]; then
      api POST "/api/messages/$pin_id/pin" "${USER_TOKEN[$owner]}" "" >/dev/null || true
      total_pins=$((total_pins + 1))
      pinned=1
    fi
  fi

  printf "    %-16s %d msgs (+%s replies, +%s reactions, +%d pin)\n" \
    "$name" "$msg_count" "$reply_count" "$rx_count" "$pinned"
done

cat <<EOF

==> Done!

   ${#USERS[@]} users         : ${USERS[*]}
   ${#GROUP_ID[@]} groups        : ${!GROUP_ID[@]}
   ${total_msgs} messages
   ${total_replies} replies
   ${total_reactions} reactions
   ${total_pins} pinned messages

Login with any seeded user:
   password: $PASSWORD

Edit $DATA_FILE to change the scenario, then re-run.
EOF
