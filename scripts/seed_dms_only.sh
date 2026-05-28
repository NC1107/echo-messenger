#!/usr/bin/env bash
# scripts/seed_dms_only.sh — minimal pure-DM scenario.
#
# 4 users, all-to-all contacts, 6 pairwise DM threads of 8-15 messages each.
# Useful for DM-focused UI testing (sidebar ordering, unread badges, last-
# message preview, scroll behavior) without group noise.
#
# Usage:
#   SEED_SERVER=http://localhost:8080 ./scripts/seed_dms_only.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./seed_v2_lib.sh
source "$SCRIPT_DIR/seed_v2_lib.sh"

SEED_SERVER="${SEED_SERVER:-http://localhost:8080}"
PASSWORD="${PASSWORD:-seedv2pass}"
STAMP="$(date +%s)"

seed_log info "echo seed v2 — DMs only"
seed_log dim "server: $SEED_SERVER  stamp: $STAMP"

USERNAMES=(piper sage rowan nico)
BIOS=(
  "loves walking meetings"
  "prefers async, will reply tomorrow"
  "lives in a different timezone, sorry"
  "fast typist, slow thinker"
)
STATUSES=(online away online dnd)

declare -A USER_ID
declare -A USER_TOKEN

seed_log info "phase 1 — users"
for i in "${!USERNAMES[@]}"; do
  uname="${USERNAMES[$i]}_$STAMP"
  seed_user "$uname" "$PASSWORD" "${BIOS[$i]}" "${STATUSES[$i]}"
  USER_ID["${USERNAMES[$i]}"]="$SEED_USER_ID"
  USER_TOKEN["${USERNAMES[$i]}"]="$SEED_USER_TOKEN"
  printf "    %-10s %s  [%s]\n" "$uname" "$SEED_USER_ID" "${STATUSES[$i]}"
done

seed_log info "phase 2 — all-to-all contacts"
for a in "${USERNAMES[@]}"; do
  for b in "${USERNAMES[@]}"; do
    [ "$a" = "$b" ] && continue
    seed_contact_accept "${USER_TOKEN[$a]}" "${USER_TOKEN[$b]}" "${b}_$STAMP"
  done
done

# 4 users -> 6 unordered pairs.
PAIRS=(
  "piper:sage"   "piper:rowan"  "piper:nico"
  "sage:rowan"   "sage:nico"    "rowan:nico"
)

TOPICS=(generic tech music gaming generic tech)

seed_log info "phase 3 — DMs"
TOTAL=0
for idx in "${!PAIRS[@]}"; do
  pair="${PAIRS[$idx]}"
  a="${pair%%:*}"
  b="${pair##*:}"
  topic="${TOPICS[$idx]}"
  count=$((8 + RANDOM % 8))   # 8-15
  seed_log dim "  $a <-> $b ($topic) — $count messages"
  for ((j=0; j<count; j++)); do
    if [ $((j % 2)) -eq 0 ]; then
      sender="$a"; recipient="$b"
    else
      sender="$b"; recipient="$a"
    fi
    text="$(random_message_text "$topic")"
    seed_dm_message "${USER_TOKEN[$sender]}" "${USER_ID[$recipient]}" "$text"
    TOTAL=$((TOTAL + 1))
  done
done

seed_ws_close_all

cat <<EOF

==> seed v2 dms-only complete

  users          : ${#USERNAMES[@]}  (prefix _$STAMP, password $PASSWORD)
  pair threads   : ${#PAIRS[@]}
  total messages : $TOTAL

  login: any of ${USERNAMES[*]}_$STAMP / $PASSWORD
EOF
