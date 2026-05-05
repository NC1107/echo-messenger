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
#   - Attachments (image / gif / video / file) via /api/media/upload
#   - Link-preview-able URLs in plain messages
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

# Like api() but returns "429" as the body when rate-limited, so callers
# can detect and retry without parsing HTTP status codes separately.
api_with_retry() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(-sS -w '\n__STATUS:%{http_code}' -X "$method" "$SERVER_URL$path" \
    -H 'Content-Type: application/json')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ]  && args+=(-d "$body")
  vlog "$method $path"
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
declare -A USER_ID
declare -A USER_TOKEN
USERS=()
while read -r u; do USERS+=("$u"); done < <(jq -r '.users[].username' "$DATA_FILE")

for u in "${USERS[@]}"; do
  # Register; retry once after 65 s if the endpoint is rate-limited
  # (3 registrations / 60 s per IP).  Fall through to login on 409 (taken).
  resp=$(api_with_retry POST /api/auth/register "" "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}")
  if [ "$resp" = "429" ]; then
    log "    [rate-limited] waiting 65 s before retrying $u…"
    sleep 65
    resp=$(api_with_retry POST /api/auth/register "" "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}")
  fi
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
  local ticket attempt
  # Ticket endpoint allows 10 per 60 s per IP; retry once after 65 s on 429.
  for attempt in 1 2; do
    ticket=$(api POST /api/auth/ws-ticket "$token" '{}' | jq -r '.ticket // empty')
    [ -n "$ticket" ] && break
    if [ "$attempt" -eq 1 ]; then
      log "    [rate-limited] ws-ticket exhausted, waiting 65 s…"
      sleep 65
    fi
  done
  if [ -z "$ticket" ]; then
    echo "WARN: failed to mint WS ticket after retry; skipping send" >&2
    return 1
  fi
  # `--no-close` keeps the socket open after stdin EOF so the server can
  # actually process the frame; we kill the client after a short wait.
  # The 1.2 s window covers TLS handshake + WS upgrade + frame round-trip
  # against a remote server (locally, ~0.3 s is enough but prod needs the
  # extra slack — without it ~30 % of frames are killed before delivery).
  printf '%s' "$payload" \
    | websocat --no-close -E "$WS_BASE/ws?ticket=$ticket" >/dev/null 2>&1 &
  local pid=$!
  sleep 1.2
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

  # Brief pause so the last WS frame has time to be persisted before we fetch.
  sleep 1

  # Pull message IDs in chronological order.
  # Route is GET /api/messages/{conversation_id} (not /conversations/{id}/messages).
  msgs_resp=$(api GET "/api/messages/$cid?limit=100" "${USER_TOKEN[$owner]}")
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
      api POST "/api/conversations/$cid/messages/$pin_id/pin" "${USER_TOKEN[$owner]}" "" >/dev/null || true
      total_pins=$((total_pins + 1))
      pinned=1
    fi
  fi

  printf "    %-16s %d msgs (+%s replies, +%s reactions, +%d pin)\n" \
    "$name" "$msg_count" "$reply_count" "$rx_count" "$pinned"
done

# ----- Phase 5: attachments + link previews ---------------------------------
# Uploads sample media (image/gif/video/file) and sends WS messages with the
# `[img:URL]` / `[video:URL]` / `[file:URL]` markers the client uses to
# render inline media.  Plain-URL messages are sent for link-preview tests.
log "==> Phase 5: attachments & link previews"
total_attachments=0
total_links=0

ASSETS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/apps/client/assets/images"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Materialise the named asset on disk and echo the path. Returns non-zero
# if the name is unknown.
make_asset() {
  case "$1" in
    logo)
      printf '%s' "$ASSETS_DIR/echo_logo_white.png" ;;
    tiny-png)
      # 1x1 transparent PNG (67 bytes, IHDR + IDAT + IEND).
      local p="$TMP_DIR/tiny.png"
      printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x00\x00\x00\x00\x3b\x7e\x9b\x55\x00\x00\x00\nIDATx\x9cc\x00\x00\x00\x02\x00\x01\xe2\x21\xbc\x33\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "$p"
      printf '%s' "$p" ;;
    tiny-gif)
      # 1x1 GIF89a (43 bytes).
      local p="$TMP_DIR/tiny.gif"
      printf 'GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02L\x01\x00;' \
        > "$p"
      printf '%s' "$p" ;;
    tiny-mp4)
      # Minimal MP4 = single ftyp box (32 bytes, isom brand).
      # Magic bytes at offset 4 ("ftyp") satisfy the server's `infer` check.
      local p="$TMP_DIR/tiny.mp4"
      printf '\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2mp41mp42' \
        > "$p"
      printf '%s' "$p" ;;
    tiny-pdf)
      # Minimal PDF — magic `%PDF-` + EOF marker. Server validates with
      # `infer` which only checks the magic, so a structural skeleton is fine.
      local p="$TMP_DIR/tiny.pdf"
      cat > "$p" <<'PDF'
%PDF-1.4
1 0 obj
<<>>
endobj
xref
0 2
0000000000 65535 f
0000000009 00000 n
trailer
<</Size 2/Root 1 0 R>>
startxref
30
%%EOF
PDF
      printf '%s' "$p" ;;
    *)
      return 1 ;;
  esac
}

mime_for_kind() {
  case "$1" in
    image) printf 'image/png' ;;
    gif)   printf 'image/gif' ;;
    video) printf 'video/mp4' ;;
    file)  printf 'application/pdf' ;;
    *)     printf 'application/octet-stream' ;;
  esac
}

marker_for_kind() {
  case "$1" in
    image|gif) printf '[img:%s]' "$2" ;;
    video)     printf '[video:%s]' "$2" ;;
    file)      printf '[file:%s]' "$2" ;;
    *)         printf '%s' "$2" ;;
  esac
}

# POST /api/media/upload (multipart). Echoes the relative URL on success or
# nothing on failure.
upload_media() {
  local token="$1" cid="$2" file="$3" mime="$4"
  local resp
  resp=$(curl -sS -m 30 -X POST "$SERVER_URL/api/media/upload" \
    -H "Authorization: Bearer $token" \
    -F "conversation_id=$cid" \
    -F "file=@$file;type=$mime" 2>/dev/null) || return 1
  printf '%s' "$resp" | jq -r '.url // empty'
}

for i in $(seq 0 $((group_count - 1))); do
  name=$(jq -r ".groups[$i].name" "$DATA_FILE")
  cid="${GROUP_ID[$name]:-}"
  [ -z "$cid" ] && continue

  att_count=$(jq ".groups[$i].attachments | length // 0" "$DATA_FILE")
  link_count=$(jq ".groups[$i].links | length // 0" "$DATA_FILE")
  group_atts=0
  group_links=0

  for a in $(seq 0 $((att_count - 1))); do
    [ "$att_count" -eq 0 ] && break
    afrom=$(jq -r ".groups[$i].attachments[$a].from" "$DATA_FILE")
    akind=$(jq -r ".groups[$i].attachments[$a].kind" "$DATA_FILE")
    aasset=$(jq -r ".groups[$i].attachments[$a].asset" "$DATA_FILE")
    acaption=$(jq -r ".groups[$i].attachments[$a].caption // empty" "$DATA_FILE")

    file=$(make_asset "$aasset" 2>/dev/null) || { echo "WARN: unknown asset '$aasset'" >&2; continue; }
    mime=$(mime_for_kind "$akind")
    url=$(upload_media "${USER_TOKEN[$afrom]}" "$cid" "$file" "$mime")
    if [ -z "$url" ]; then
      echo "WARN: upload failed for $name ($aasset by $afrom)" >&2
      continue
    fi

    marker=$(marker_for_kind "$akind" "$url")
    body="$marker"
    [ -n "$acaption" ] && body=$(printf '%s\n%s' "$marker" "$acaption")

    payload=$(jq -nc --arg cid "$cid" --arg t "$body" \
      '{type:"send_message", conversation_id:$cid, content:$t}')
    ws_send_one "${USER_TOKEN[$afrom]}" "$payload" || true
    total_attachments=$((total_attachments + 1))
    group_atts=$((group_atts + 1))
  done

  for l in $(seq 0 $((link_count - 1))); do
    [ "$link_count" -eq 0 ] && break
    lfrom=$(jq -r ".groups[$i].links[$l].from" "$DATA_FILE")
    lurl=$(jq -r ".groups[$i].links[$l].url" "$DATA_FILE")
    llead=$(jq -r ".groups[$i].links[$l].lead // empty" "$DATA_FILE")

    body="$lurl"
    [ -n "$llead" ] && body=$(printf '%s %s' "$llead" "$lurl")

    payload=$(jq -nc --arg cid "$cid" --arg t "$body" \
      '{type:"send_message", conversation_id:$cid, content:$t}')
    ws_send_one "${USER_TOKEN[$lfrom]}" "$payload" || true
    total_links=$((total_links + 1))
    group_links=$((group_links + 1))
  done

  if [ "$group_atts" -gt 0 ] || [ "$group_links" -gt 0 ]; then
    printf "    %-16s +%d attachments, +%d links\n" \
      "$name" "$group_atts" "$group_links"
  fi
done

cat <<EOF

==> Done!

   ${#USERS[@]} users         : ${USERS[*]}
   ${#GROUP_ID[@]} groups        : ${!GROUP_ID[@]}
   ${total_msgs} messages
   ${total_replies} replies
   ${total_reactions} reactions
   ${total_pins} pinned messages
   ${total_attachments} attachments
   ${total_links} link previews

Login with any seeded user:
   password: $PASSWORD

Edit $DATA_FILE to change the scenario, then re-run.
EOF
