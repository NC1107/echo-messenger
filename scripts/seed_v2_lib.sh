#!/usr/bin/env bash
# scripts/seed_v2_lib.sh — sourceable helper library for the Echo Messenger
# seed-v2 scenario scripts.  Builds on the public REST + WS API only — no DB
# access, no fixtures, no privileged endpoints — so it runs against localhost
# or any reachable Echo server.
#
# Usage:
#   source "$(dirname "$0")/seed_v2_lib.sh"
#
#   seed_user alice secret "bio" online
#   echo "Created $SEED_USER_ID with token $SEED_USER_TOKEN"
#
# Conventions:
#   - Bash 4+ (associative arrays, mapfile).
#   - Functions that mint a user/group/message echo nothing; results are
#     returned via the SEED_* globals listed beside each helper.
#   - All HTTP requests go through `_seed_curl` so they share the same
#     User-Agent (Cloudflare blocks no-UA) and timeout.
#   - The base URL is `${SEED_SERVER:-http://localhost:8080}`.
#
# Required tools: curl, jq.  websocat is NOT required — seed_v2 sticks to REST
# endpoints so it can run from minimal CI containers.

set -euo pipefail

# ---------------------------------------------------------------------------
# Error trap: print the failing line + command on any non-zero exit.
# ---------------------------------------------------------------------------
_seed_on_err() {
  local line="$1" cmd="$2"
  printf '\033[31mseed_v2_lib: failed at line %s: %s\033[0m\n' \
    "$line" "$cmd" >&2
}
trap '_seed_on_err "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SEED_SERVER="${SEED_SERVER:-http://localhost:8080}"
SEED_USER_AGENT="Mozilla/5.0 echo-seed"
SEED_TIMEOUT="${SEED_TIMEOUT:-15}"

# Last-call outputs.  Functions document which globals they populate.
SEED_USER_ID=""
SEED_USER_TOKEN=""
SEED_GROUP_ID=""
SEED_MESSAGE_ID=""
SEED_DM_CONVERSATION_ID=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# seed_log <level> <msg>    level in {info, warn, error, ok, dim}
seed_log() {
  local level="$1"; shift
  local msg="$*"
  local color reset='\033[0m'
  case "$level" in
    info)  color='\033[36m' ;;  # cyan
    ok)    color='\033[32m' ;;  # green
    warn)  color='\033[33m' ;;  # yellow
    error) color='\033[31m' ;;  # red
    dim)   color='\033[2m'  ;;  # dim
    *)     color=''         ;;
  esac
  printf '%b[%s]%b %s\n' "$color" "$level" "$reset" "$msg" >&2
}

# ---------------------------------------------------------------------------
# Low-level HTTP
# ---------------------------------------------------------------------------
# _seed_curl <method> <path> [token] [json_body]
# Echoes the response body. Non-2xx still echoes body so callers can inspect.
_seed_curl() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(
    -sS -m "$SEED_TIMEOUT"
    -X "$method"
    "$SEED_SERVER$path"
    -H "Content-Type: application/json"
    -H "User-Agent: $SEED_USER_AGENT"
  )
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ]  && args+=(-d "$body")
  curl "${args[@]}"
}

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
# seed_user <username> <password> [bio] [status]
#   Registers (or logs in if taken) and optionally sets profile + presence.
#   Populates: SEED_USER_ID, SEED_USER_TOKEN
seed_user() {
  local username="$1" password="$2" bio="${3:-}" status="${4:-}"
  local body resp
  body=$(jq -nc --arg u "$username" --arg p "$password" \
    '{username:$u, password:$p}')
  resp=$(_seed_curl POST /api/auth/register "" "$body" || true)
  if [ -z "$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null)" ]; then
    # Username already exists (or registration rate-limited): fall back to login.
    resp=$(_seed_curl POST /api/auth/login "" "$body")
  fi
  SEED_USER_ID=$(jq -r '.user_id // empty' <<<"$resp")
  SEED_USER_TOKEN=$(jq -r '.access_token // empty' <<<"$resp")
  if [ -z "$SEED_USER_ID" ] || [ -z "$SEED_USER_TOKEN" ]; then
    seed_log error "register/login failed for $username: $resp"
    return 1
  fi
  if [ -n "$bio" ]; then
    local pbody
    pbody=$(jq -nc --arg b "$bio" '{bio:$b}')
    _seed_curl PATCH /api/users/me/profile "$SEED_USER_TOKEN" "$pbody" >/dev/null || true
  fi
  if [ -n "$status" ]; then
    seed_set_presence "$SEED_USER_TOKEN" "$status" || true
  fi
}

# seed_login <username> <password>
#   Login-only; populates SEED_USER_ID + SEED_USER_TOKEN.
seed_login() {
  local username="$1" password="$2"
  local body resp
  body=$(jq -nc --arg u "$username" --arg p "$password" \
    '{username:$u, password:$p}')
  resp=$(_seed_curl POST /api/auth/login "" "$body")
  SEED_USER_ID=$(jq -r '.user_id // empty' <<<"$resp")
  SEED_USER_TOKEN=$(jq -r '.access_token // empty' <<<"$resp")
  if [ -z "$SEED_USER_ID" ] || [ -z "$SEED_USER_TOKEN" ]; then
    seed_log error "login failed for $username: $resp"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Contacts
# ---------------------------------------------------------------------------
# seed_contact_accept <user_a_token> <user_b_token> <user_b_username>
#   A sends request to B's username, B accepts.  Idempotent: already-contacts
#   responses are silently ignored.
seed_contact_accept() {
  local a_token="$1" b_token="$2" b_username="$3"
  local body resp contact_id
  body=$(jq -nc --arg u "$b_username" '{username:$u}')
  resp=$(_seed_curl POST /api/contacts/request "$a_token" "$body" || true)
  contact_id=$(jq -r '.contact_id // empty' <<<"$resp" 2>/dev/null || true)
  if [ -z "$contact_id" ]; then
    return 0  # already contacts, or request rejected — fine
  fi
  local abody
  abody=$(jq -nc --arg c "$contact_id" '{contact_id:$c}')
  _seed_curl POST /api/contacts/accept "$b_token" "$abody" >/dev/null || true
}

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------
# seed_group <owner_token> <name> [description] [is_encrypted=0]
#   Creates a public group, optionally end-to-end encrypted.
#   Populates: SEED_GROUP_ID
seed_group() {
  local owner_token="$1" name="$2" description="${3:-}" is_encrypted="${4:-0}"
  local enc_bool=false
  [ "$is_encrypted" = "1" ] || [ "$is_encrypted" = "true" ] && enc_bool=true
  local body resp
  body=$(jq -nc \
    --arg n "$name" \
    --arg d "$description" \
    --argjson e "$enc_bool" \
    '{name:$n, description:$d, is_public:true, is_encrypted:$e, member_ids:[]}')
  resp=$(_seed_curl POST /api/groups "$owner_token" "$body")
  SEED_GROUP_ID=$(jq -r '.id // empty' <<<"$resp")
  if [ -z "$SEED_GROUP_ID" ]; then
    seed_log error "group create failed: $resp"
    return 1
  fi
}

# seed_group_invite_accept <owner_token> <member_token> <group_id>
#   Owner mints an invite, member accepts it.  Uses the public-invite flow so
#   we don't need each member's user_id upfront.
seed_group_invite_accept() {
  local owner_token="$1" member_token="$2" group_id="$3"
  local resp token abody
  # Create a single-use invite (default expiry / max_uses left to server).
  resp=$(_seed_curl POST "/api/groups/$group_id/invites" "$owner_token" '{}')
  token=$(jq -r '.token // empty' <<<"$resp")
  if [ -z "$token" ]; then
    # Fallback: direct join via member token (works for public groups).
    _seed_curl POST "/api/groups/$group_id/join" "$member_token" '{}' >/dev/null || true
    return 0
  fi
  _seed_curl POST "/api/invites/$token/accept" "$member_token" '{}' >/dev/null || true
}

# ---------------------------------------------------------------------------
# Messaging
# ---------------------------------------------------------------------------
# seed_dm_message <sender_token> <recipient_user_id> <plaintext>
#   1:1 message via REST: POST /api/conversations/dm to ensure the conversation
#   exists (idempotent — server returns the existing conversation_id), then
#   the WS protocol's storage layer is NOT used here; we rely on the same
#   POST-then-fetch shape the client uses today.  The actual send goes
#   through the WS /ws endpoint via ws-ticket, mirroring what seed_full_demo
#   does.  Confirmed the only server-side message-write paths are:
#     - WS `send_message` frame (apps/server/src/ws/message_service/mod.rs)
#     - There is NO REST POST /api/messages — get/list/edit/delete only.
#   So we use a transient WS connection per send.
#   Populates: SEED_DM_CONVERSATION_ID, SEED_MESSAGE_ID (best-effort)
seed_dm_message() {
  local sender_token="$1" recipient_user_id="$2" plaintext="$3"
  # Find-or-create the DM conversation.
  local body resp cid
  body=$(jq -nc --arg p "$recipient_user_id" '{peer_user_id:$p}')
  resp=$(_seed_curl POST /api/conversations/dm "$sender_token" "$body")
  cid=$(jq -r '.conversation_id // empty' <<<"$resp")
  if [ -z "$cid" ]; then
    seed_log error "create_dm failed: $resp"
    return 1
  fi
  SEED_DM_CONVERSATION_ID="$cid"
  seed_group_message "$sender_token" "$cid" "$plaintext"
}

# seed_group_message <sender_token> <conversation_id> <plaintext> [reply_to_id]
#   Sends a message into a group (or DM) conversation via WS.  Returns the
#   most recent message id for that conversation in SEED_MESSAGE_ID (best
#   effort; server message IDs aren't echoed back on the open frame, so we
#   refetch /api/messages/<cid>?limit=1 after the send).
seed_group_message() {
  local sender_token="$1" cid="$2" plaintext="$3" reply_to_id="${4:-}"
  local payload
  if [ -n "$reply_to_id" ]; then
    payload=$(jq -nc --arg cid "$cid" --arg t "$plaintext" --arg r "$reply_to_id" \
      '{type:"send_message", conversation_id:$cid, content:$t, reply_to_id:$r}')
  else
    payload=$(jq -nc --arg cid "$cid" --arg t "$plaintext" \
      '{type:"send_message", conversation_id:$cid, content:$t}')
  fi
  _seed_ws_send "$sender_token" "$payload"
  # Best-effort: refetch the latest message id so callers can chain reactions
  # / replies.  Only one round-trip per message — heavy seeders that don't
  # need IDs should pass an empty $4 and ignore SEED_MESSAGE_ID.
  local resp
  resp=$(_seed_curl GET "/api/messages/$cid?limit=1" "$sender_token" || true)
  SEED_MESSAGE_ID=$(jq -r '.[0].id // empty' <<<"$resp" 2>/dev/null || echo "")
}

# Internal: send one WS frame and tear the socket down.  Requires websocat.
_seed_ws_send() {
  local token="$1" payload="$2"
  if ! command -v websocat >/dev/null 2>&1; then
    seed_log error "websocat is required for WS sends (cargo install websocat)"
    return 1
  fi
  local ticket_resp ticket ws_base
  ticket_resp=$(_seed_curl POST /api/auth/ws-ticket "$token" '{}')
  ticket=$(jq -r '.ticket // empty' <<<"$ticket_resp")
  if [ -z "$ticket" ]; then
    seed_log warn "ws-ticket failed (rate limit?); skipping send"
    return 1
  fi
  ws_base="$(printf '%s' "$SEED_SERVER" \
    | sed -e 's|^http://|ws://|' -e 's|^https://|wss://|')"
  printf '%s' "$payload" \
    | websocat --no-close -E "$ws_base/ws?ticket=$ticket" \
        >/dev/null 2>&1 &
  local pid=$!
  sleep 0.6
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Reactions / Presence
# ---------------------------------------------------------------------------
# seed_reaction <sender_token> <message_id> <emoji>
seed_reaction() {
  local sender_token="$1" message_id="$2" emoji="$3"
  local body
  body=$(jq -nc --arg e "$emoji" '{emoji:$e}')
  _seed_curl POST "/api/messages/$message_id/reactions" "$sender_token" "$body" \
    >/dev/null || true
}

# seed_set_presence <token> <state>
#   state in {online, away, dnd, invisible}.  The server-side enum does not
#   include a literal "offline" — clients map offline → invisible — so this
#   helper does the same.
seed_set_presence() {
  local token="$1" state="$2"
  case "$state" in
    offline) state="invisible" ;;
    online|away|dnd|invisible) ;;
    *)
      seed_log warn "unknown presence '$state', falling back to online"
      state="online" ;;
  esac
  local body
  body=$(jq -nc --arg s "$state" '{status:$s}')
  _seed_curl PATCH /api/users/me/status "$token" "$body" >/dev/null || true
}

# ---------------------------------------------------------------------------
# Random / time helpers
# ---------------------------------------------------------------------------
# weighted_choice "70:20:10" "common:rare:epic"
#   Echoes one of the colon-separated values according to the weights.
weighted_choice() {
  local weights_str="$1" values_str="$2"
  IFS=':' read -ra weights <<<"$weights_str"
  IFS=':' read -ra values  <<<"$values_str"
  if [ "${#weights[@]}" -ne "${#values[@]}" ]; then
    seed_log error "weighted_choice: weights/values length mismatch"
    return 1
  fi
  local total=0 w
  for w in "${weights[@]}"; do total=$((total + w)); done
  local r=$((RANDOM % total))
  local cum=0 i
  for i in "${!weights[@]}"; do
    cum=$((cum + weights[i]))
    if [ "$r" -lt "$cum" ]; then
      printf '%s' "${values[$i]}"
      return 0
    fi
  done
  printf '%s' "${values[-1]}"
}

# random_message_text [topic]    topic in {tech, gaming, music, generic}
random_message_text() {
  local topic="${1:-generic}"
  local -a pool
  case "$topic" in
    tech)
      pool=(
        "Anyone else seeing flaky CI on the rust job today?"
        "Just upgraded to flutter 3.41 and analyze is way faster."
        "TIL postgres' DISTINCT ON beats GROUP BY for last-per-key."
        "Push notifications on iOS background still mostly a mystery to me."
        "Riverpod 3 migration is mostly fine if you avoid family providers."
        "Anyone got a clean pattern for retrying websocket reconnects with jitter?"
        "Docker BuildKit cache mounts saved me 10 min per build."
        "End-to-end tests caught the bug, unit tests missed it. Again."
        "Cargo audit flagged a transitive dep — checking if it's actually reachable."
        "Cloudflare blocking curl with no UA cost me an hour today."
      )
      ;;
    gaming)
      pool=(
        "anyone up for a few rounds tonight?"
        "the new patch made the early game way more interesting"
        "lol that lobby was rough, 3 disconnects"
        "lfg ranked, need one more"
        "honestly the soundtrack is doing all the heavy lifting"
        "rng was not on our side that match"
        "stream's up in 10 if anyone wants to watch"
        "finally beat the boss after like 40 tries"
        "loadout question: smg or rifle for objective?"
        "vc on discord, mic check"
      )
      ;;
    music)
      pool=(
        "new album dropped, listening on loop"
        "anyone got recs in the same vibe as the latest Khruangbin?"
        "found a sick lofi playlist for late night coding"
        "saw them live last month — opener was actually better"
        "the bass on this track is unreal with headphones"
        "vinyl pressing finally arrived, no scratches"
        "mixing my first track this weekend, wish me luck"
        "spotify wrapped is gonna be embarrassing this year"
        "midnights deluxe or just regular, which version"
        "concert tickets next month, hype"
      )
      ;;
    *)
      pool=(
        "morning everyone"
        "lunch break, brb in 30"
        "how's everyone's week going"
        "rough day, going to log off early"
        "did you see the news today"
        "weekend plans?"
        "coffee number 3 and still tired"
        "anyone else completely swamped right now"
        "sun finally came out, going for a walk"
        "calling it a day, see you all tomorrow"
      )
      ;;
  esac
  printf '%s' "${pool[$((RANDOM % ${#pool[@]}))]}"
}

# backdate_seconds <offset_seconds>
#   Echoes a UTC ISO-8601 timestamp `offset` seconds before now.  Used for
#   building human-readable scenario summaries; note that the server stamps
#   `messages.created_at` itself on insert — we can't backdate the row via
#   the public API, only annotate the log output.
backdate_seconds() {
  local offset="$1"
  date -u -d "@$(( $(date -u +%s) - offset ))" \
    +"%Y-%m-%dT%H:%M:%SZ"
}

# ---------------------------------------------------------------------------
# Sanity check on source: tools.
# ---------------------------------------------------------------------------
for _t in curl jq; do
  if ! command -v "$_t" >/dev/null 2>&1; then
    printf 'seed_v2_lib: missing required tool: %s\n' "$_t" >&2
    return 1 2>/dev/null || exit 1
  fi
done
unset _t
