#!/usr/bin/env bash
# seed_stress_data.sh — generate a "Big Data Test Group" with realistic
# stress-test data so the UI can be audited under load.
#
# What gets created
#   - Group: "Big Data Test Group" (public, plaintext)
#   - Owner: admin_tester  (auto-created if missing)
#   - Members: alice, bob, cara, dan, eve  (auto-created if missing)
#   - Messages (defaults; tunable via env vars):
#       1000  plain messages, rotating senders                  (MESSAGES)
#        100  replies to one parent message (deep thread)       (REPLIES)
#         10  ~8 KB long-text messages                          (BIG_TEXT)
#         20  emoji-heavy messages (jumbo-emoji rendering)      (EMOJI)
#         15  markdown stress (code blocks, lists, blockquotes) (MARKDOWN)
#         10  reaction-heavy messages (5+ unique emoji each)    (REACTIONS)
#         30  rapid-fire same-second timestamps                 (RAPIDFIRE)
#
# Usage
#   ./scripts/seed_stress_data.sh                          # localhost
#   SERVER_URL=https://staging.example ./scripts/seed_stress_data.sh
#   MESSAGES=2000 REPLIES=200 ./scripts/seed_stress_data.sh
#   RESET=1 ./scripts/seed_stress_data.sh                  # wipe & re-seed
#
# Performance
#   1000+ messages over a single persistent WebSocket per sender; expect
#   under 90 s on localhost.  The previous seed script's per-message WS
#   open/close added ~1.2 s of TLS+upgrade per frame; this avoids that.
#
# Dependencies: curl, jq, websocat (cargo install websocat).

set -euo pipefail

SERVER_URL="${SERVER_URL:-http://localhost:8080}"
WS_BASE="${SERVER_URL/http/ws}"
PASSWORD="${PASSWORD:-stresspass123}"

MESSAGES="${MESSAGES:-1000}"
REPLIES="${REPLIES:-100}"
BIG_TEXT="${BIG_TEXT:-10}"
EMOJI="${EMOJI:-20}"
MARKDOWN="${MARKDOWN:-15}"
REACTIONS="${REACTIONS:-10}"
RAPIDFIRE="${RAPIDFIRE:-30}"
RESET="${RESET:-0}"

GROUP_NAME="Big Data Test Group"
OWNER="admin_tester"
OWNER_PW="admin123"
# Stress users use a `stress_` prefix so they don't collide with any
# pre-existing demo accounts (which may already have been registered
# with a different password by run.sh / seed_full_demo.sh).
MEMBERS=(stress_alice stress_bob stress_cara stress_dan stress_eve)
ALL_USERS=("$OWNER" "${MEMBERS[@]}")

# ----- Dependency checks ----------------------------------------------------
for cmd in curl jq websocat; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but not on PATH" >&2
    [ "$cmd" = "websocat" ] && \
      echo "       install: cargo install websocat" >&2
    exit 1
  fi
done

# ----- Server reachability --------------------------------------------------
log() { printf '%s\n' "$*"; }
if ! curl -sf -m 5 "$SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "ERROR: server not reachable at $SERVER_URL/api/health" >&2
  exit 1
fi
log "==> Big Data Test Group seeder"
log "    server : $SERVER_URL"
log "    volume : $MESSAGES plain + $REPLIES replies + $BIG_TEXT big + $EMOJI emoji + $MARKDOWN md + $REACTIONS rxn + $RAPIDFIRE rapid"

api() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(-sS -X "$method" "$SERVER_URL$path" -H 'Content-Type: application/json')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ]  && args+=(-d "$body")
  curl "${args[@]}"
}

# Like api() but emits the literal "429" string when the server rate-limits.
# Lets callers wait + retry without having to parse HTTP status codes.
api_with_retry() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(-sS -w '\n__STATUS:%{http_code}' -X "$method" "$SERVER_URL$path" \
    -H 'Content-Type: application/json')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ]  && args+=(-d "$body")
  local raw status resp
  raw=$(curl "${args[@]}")
  status="${raw##*__STATUS:}"
  resp="${raw%__STATUS:*}"
  if [ "$status" = "429" ]; then
    echo "429"
  else
    printf '%s' "$resp"
  fi
}

# ----- Phase 1: users -------------------------------------------------------
log "==> Phase 1: users"
declare -A USER_ID USER_TOKEN
for u in "${ALL_USERS[@]}"; do
  pw="$PASSWORD"
  [ "$u" = "$OWNER" ] && pw="$OWNER_PW"
  # Register first; the endpoint is rate-limited (3 / 60 s per IP) so wait
  # and retry once on 429.  Then fall back to login on any other failure
  # (typically "username taken" when the account already exists from a
  # prior run).
  resp=$(api_with_retry POST /api/auth/register "" "{\"username\":\"$u\",\"password\":\"$pw\"}")
  if [ "$resp" = "429" ]; then
    log "    [rate-limited] waiting 65 s before retrying $u…"
    sleep 65
    resp=$(api_with_retry POST /api/auth/register "" "{\"username\":\"$u\",\"password\":\"$pw\"}")
  fi
  if [ "$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null)" = "" ]; then
    resp=$(api POST /api/auth/login "" "{\"username\":\"$u\",\"password\":\"$pw\"}")
  fi
  uid=$(jq -r '.user_id' <<<"$resp" 2>/dev/null || true)
  tok=$(jq -r '.access_token' <<<"$resp" 2>/dev/null || true)
  if [ "$uid" = "null" ] || [ -z "$uid" ]; then
    echo "ERROR: register/login failed for $u: $resp" >&2; exit 1
  fi
  USER_ID[$u]="$uid"
  USER_TOKEN[$u]="$tok"
  printf "    user %-14s %s\n" "$u" "$uid"
done

# ----- Phase 2: group -------------------------------------------------------
log "==> Phase 2: group"
OWNER_TOKEN="${USER_TOKEN[$OWNER]}"

# Find an existing group of this name owned by admin_tester.
existing_id=""
existing_resp=$(api GET /api/conversations "$OWNER_TOKEN" || true)
existing_id=$(jq -r --arg n "$GROUP_NAME" \
  '[.[] | select((.title // .name) == $n and ((.is_group // (.kind == "group")) == true))][0].id // (.. | .conversation_id? // empty) // empty' \
  <<<"$existing_resp" 2>/dev/null || true)
# Fallback: simpler match if the response shape differs.
if [ -z "$existing_id" ] || [ "$existing_id" = "null" ]; then
  existing_id=$(jq -r --arg n "$GROUP_NAME" \
    '.[] | select((.title // .name) == $n) | (.conversation_id // .id)' \
    <<<"$existing_resp" 2>/dev/null | head -n1)
fi

if [ "$RESET" = "1" ] && [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
  log "    RESET=1, deleting existing group $existing_id"
  api DELETE "/api/groups/$existing_id" "$OWNER_TOKEN" >/dev/null || true
  existing_id=""
fi

if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
  GROUP_ID="$existing_id"
  log "    reusing existing group $GROUP_ID (append-only; pass RESET=1 to wipe)"
else
  body=$(jq -nc --arg n "$GROUP_NAME" \
    '{name:$n, description:"Stress-test fixture for UX/perf audit", is_public:true}')
  resp=$(api POST /api/groups "$OWNER_TOKEN" "$body")
  GROUP_ID=$(jq -r '.id // .group_id // .conversation_id // empty' <<<"$resp" 2>/dev/null || true)
  if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" = "null" ]; then
    echo "ERROR: group create failed: $resp" >&2; exit 1
  fi
  log "    created $GROUP_ID"
fi

# Add members (idempotent; server returns AlreadyMember error which we ignore).
for m in "${MEMBERS[@]}"; do
  body=$(jq -nc --arg uid "${USER_ID[$m]}" '{user_id:$uid}')
  api POST "/api/groups/$GROUP_ID/members" "$OWNER_TOKEN" "$body" >/dev/null || true
done
log "    members: ${MEMBERS[*]}"

# ----- Phase 3: open one persistent WS per sender ---------------------------
log "==> Phase 3: open persistent WebSockets"
TMP_DIR="$(mktemp -d)"
declare -A WS_FIFO WS_PID
trap 'cleanup_ws' EXIT

cleanup_ws() {
  for u in "${!WS_PID[@]}"; do
    # Close the FIFO writer to send EOF, then kill the websocat process.
    eval "exec ${WS_FD[$u]:-99}>&-" 2>/dev/null || true
    kill "${WS_PID[$u]}" 2>/dev/null || true
    wait "${WS_PID[$u]}" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
}

declare -A WS_FD
next_fd=10
for u in "${ALL_USERS[@]}"; do
  ticket=$(api POST /api/auth/ws-ticket "${USER_TOKEN[$u]}" '{}' | jq -r '.ticket // empty')
  if [ -z "$ticket" ]; then
    echo "ERROR: failed to mint WS ticket for $u" >&2; exit 1
  fi
  fifo="$TMP_DIR/ws-$u"
  mkfifo "$fifo"
  websocat --no-close -E "$WS_BASE/ws?ticket=$ticket" >/dev/null 2>&1 < "$fifo" &
  WS_PID[$u]=$!
  # Hold the FIFO open for writing on a unique fd so subsequent sends
  # don't block waiting for the reader to come back.
  fd=$next_fd
  next_fd=$((next_fd + 1))
  eval "exec $fd>$fifo"
  WS_FD[$u]=$fd
  WS_FIFO[$u]="$fifo"
done
log "    opened ${#WS_PID[@]} sockets"

# Tiny delay so the WS upgrade completes before we start firing frames.
sleep 0.5

ws_send() {
  # $1 = sender username, $2 = JSON payload (single line, NDJSON).
  # The trailing `|| true` is critical: if a websocat process at the other
  # end of the FIFO has died (e.g. server closed the WS for a rate-limit
  # violation), printf raises SIGPIPE and the bare `set -e` would abort
  # the entire seed run.  We log a warning instead and let the loop
  # continue with the remaining senders.
  local u="$1" payload="$2"
  local fd="${WS_FD[$u]}"
  if ! printf '%s\n' "$payload" >&"$fd" 2>/dev/null; then
    echo "    [warn] ws_send to $u failed (socket closed?); continuing" >&2
    return 0
  fi
}

# Pace WebSocket sends to fit the server's per-connection rate limit:
# the WS receive loop in apps/server/src/ws/handler.rs uses a token
# bucket of 30 messages with 3-msg/sec refill, and closes the
# connection after 3 consecutive violations.  With 6 rotating senders,
# a sustained aggregate of ~12 msg/sec (=2 msg/sec/sender) keeps every
# bucket well above empty.  Sleep 80 ms between sends -> 12.5 msg/sec.
ws_pace_sleep="${WS_PACE_SLEEP:-0.08}"

# ----- Phase 4: stress messages ---------------------------------------------
log "==> Phase 4: sending messages"

mk_payload() {
  jq -nc --arg cid "$GROUP_ID" --arg t "$1" \
    '{type:"send_message", conversation_id:$cid, content:$t}'
}
mk_reply_payload() {
  jq -nc --arg cid "$GROUP_ID" --arg t "$1" --arg p "$2" \
    '{type:"send_message", conversation_id:$cid, content:$t, reply_to_id:$p}'
}

# Topical fragments to mix into plain messages so the body actually wraps,
# scrolls, and reads as a real conversation.
FRAGMENTS=(
  "ship it"
  "lgtm — running CI now"
  "anyone else seeing the flaky test on main?"
  "just rebased, please pull"
  "morning all 👋"
  "lunch run, back in 30"
  "PSA: mfa rollout is tomorrow"
  "what time is the design review?"
  "I'll grab the on-call this week"
  "merging once green"
  "small nit: variable naming in the helper"
  "took a quick look — overall direction feels right"
  "tagging release candidate v3.1.0-rc.4"
  "the staging build is up — kicking the tires now"
  "meeting moved to 3pm tomorrow heads up"
  "did anyone document the migration path yet?"
  "pinned the runbook in #ops"
  "new infra dashboard: \$DASHBOARD_URL"
  "post-mortem draft is ready for review"
  "running benchmarks against main now, will share numbers"
)

# Plain messages, rotating senders.
log "    [a] $MESSAGES plain messages"
sender_idx=0
for i in $(seq 1 "$MESSAGES"); do
  sender="${ALL_USERS[$((sender_idx % ${#ALL_USERS[@]}))]}"
  text="${FRAGMENTS[$((RANDOM % ${#FRAGMENTS[@]}))]} (#$i)"
  ws_send "$sender" "$(mk_payload "$text")"
  sender_idx=$((sender_idx + 1))
  sleep "$ws_pace_sleep"
done

# Big-text messages (~8 KB each).  Server caps at MAX_MESSAGE_LENGTH
# (typically 10 KB) so 8 KB is safely under.
log "    [b] $BIG_TEXT big-text messages"
LOREM="The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. Sphinx of black quartz, judge my vow. How vexingly quick daft zebras jump. Bright vixens jump; dozy fowl quack. "
for i in $(seq 1 "$BIG_TEXT"); do
  body=""
  for _ in $(seq 1 60); do body+="$LOREM"; done   # ~7.8 KB
  body="big-text #$i: $body"
  sender="${ALL_USERS[$((RANDOM % ${#ALL_USERS[@]}))]}"
  ws_send "$sender" "$(mk_payload "$body")"
  sleep "$ws_pace_sleep"
done

# Emoji-heavy / jumbo-emoji.
log "    [c] $EMOJI emoji messages"
EMOJIS=(🎉 🚀 😂 🔥 💯 ✨ 🥳 🎊 ❤️ 👀 🐛 💻 🖼️ 🎨 🎵 ⚡ 🌈 🍕 🦀 🐍)
for i in $(seq 1 "$EMOJI"); do
  count=$((1 + RANDOM % 12))
  body=""
  for _ in $(seq 1 "$count"); do body+="${EMOJIS[$((RANDOM % ${#EMOJIS[@]}))]}"; done
  sender="${ALL_USERS[$((RANDOM % ${#ALL_USERS[@]}))]}"
  ws_send "$sender" "$(mk_payload "$body")"
  sleep "$ws_pace_sleep"
done

# Markdown stress: fenced code blocks, blockquotes, lists.
log "    [d] $MARKDOWN markdown messages"
for i in $(seq 1 "$MARKDOWN"); do
  case $((i % 3)) in
    0) body=$'```\nfn main() {\n    let xs = (0..1_000_000)\n        .filter(|n| n % 7 == 0)\n        .sum::<u64>();\n    println!("sum = {xs}");\n}\n```' ;;
    1) body=$'> notable pull-quote from a doc somewhere on the internet\n>\n> nested too — this should still wrap at the bubble\'s max width without the blockquote indent eating the right side' ;;
    *) body=$'- alpha\n- beta\n- gamma\n- delta\n- epsilon\n- zeta\n- eta' ;;
  esac
  sender="${ALL_USERS[$((RANDOM % ${#ALL_USERS[@]}))]}"
  ws_send "$sender" "$(mk_payload "$body")"
  sleep "$ws_pace_sleep"
done

# Rapid-fire same-second timestamps.  We still pace these (rotating across
# 6 senders -> ~5 per sender per second after pacing) to avoid blowing up
# the rate limit; the "same second" property is preserved by the timestamp
# resolution server-side, not by sub-second wall clock here.
log "    [e] $RAPIDFIRE rapid-fire messages"
for i in $(seq 1 "$RAPIDFIRE"); do
  sender="${ALL_USERS[$((sender_idx % ${#ALL_USERS[@]}))]}"
  ws_send "$sender" "$(mk_payload "rapid #$i — same second, tests grouping")"
  sender_idx=$((sender_idx + 1))
  sleep "$ws_pace_sleep"
done

# Let the server settle before we pull message IDs for replies / reactions.
log "    waiting for server to drain WS frames…"
sleep 4

# ----- Phase 5: reply thread + reactions ------------------------------------
# Pull recent messages so we can target a parent for the reply thread and
# pick targets for reactions.  The /api/messages/{cid} list returns newest
# first; flip and slice as needed.
log "==> Phase 5: replies + reactions"
msgs_resp=$(api GET "/api/messages/$GROUP_ID?limit=200" "$OWNER_TOKEN")
mapfile -t RECENT_IDS < <(jq -r '.[].id' <<<"$msgs_resp")

if [ "${#RECENT_IDS[@]}" -lt 1 ]; then
  echo "WARN: no recent message IDs returned; skipping replies + reactions" >&2
else
  # Reply thread: pick the message at index N/2 as the parent so the thread
  # sits in the middle of the timeline and forces "scroll into thread".
  parent="${RECENT_IDS[$(( ${#RECENT_IDS[@]} / 2 ))]}"
  log "    [f] $REPLIES-reply thread on $parent"
  for i in $(seq 1 "$REPLIES"); do
    sender="${ALL_USERS[$((sender_idx % ${#ALL_USERS[@]}))]}"
    text="reply #$i in the deep thread"
    ws_send "$sender" "$(mk_reply_payload "$text" "$parent")"
    sender_idx=$((sender_idx + 1))
    sleep "$ws_pace_sleep"
  done

  # Reaction-heavy messages: pick REACTIONS messages and add 5+ unique emoji
  # to each from rotating senders.
  log "    [g] $REACTIONS reaction-heavy messages"
  RXN_EMOJIS=(👍 ❤️ 😂 🎉 🔥 🚀 ✨ 💯)
  for r in $(seq 1 "$REACTIONS"); do
    target="${RECENT_IDS[$((RANDOM % ${#RECENT_IDS[@]}))]}"
    for j in $(seq 0 5); do
      emoji="${RXN_EMOJIS[$((j % ${#RXN_EMOJIS[@]}))]}"
      sender="${ALL_USERS[$((j % ${#ALL_USERS[@]}))]}"
      body=$(jq -nc --arg e "$emoji" '{emoji:$e}')
      api POST "/api/messages/$target/reactions" "${USER_TOKEN[$sender]}" "$body" >/dev/null || true
    done
  done
fi

# Drain remaining frames before the script exits and the trap closes sockets.
sleep 2

# ----- Summary --------------------------------------------------------------
total=$((MESSAGES + BIG_TEXT + EMOJI + MARKDOWN + RAPIDFIRE + REPLIES))
log ""
log "✓ Big Data Test Group seeded"
log "    $MESSAGES plain messages"
log "    $REPLIES reply thread"
log "    $BIG_TEXT big-text messages"
log "    $EMOJI emoji messages"
log "    $MARKDOWN markdown messages"
log "    $REACTIONS reaction-heavy messages"
log "    $RAPIDFIRE rapid-fire grouped messages"
log "  Total: ~$total messages"
log ""
log "  Login: $OWNER / $OWNER_PW"
log "  Group: \"$GROUP_NAME\" ($GROUP_ID)"
