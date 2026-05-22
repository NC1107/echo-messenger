#!/usr/bin/env bash
# scripts/seed_realistic_day.sh
#
# Exercises gaps the existing seeders miss:
#   * a real rhythm to the day (standup, async chat, lunch lull, decision
#     thread, EOD updates) instead of one big firehose
#   * mixed plaintext + ENCRYPTED groups (is_encrypted=true), so the
#     "[Encrypted]" placeholder + lock indicator code paths are populated
#   * pairwise DMs alongside groups
#   * varied presence states (online / away / dnd / invisible)
#   * reply threads that actually branch — replies to several different
#     parents, not all chained to the first message
#
# Usage:
#   SEED_SERVER=http://localhost:8080 ./scripts/seed_realistic_day.sh
#
# Idempotency: usernames are prefixed with the current epoch second so
# reruns create fresh accounts instead of colliding on the unique index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./seed_v2_lib.sh
source "$SCRIPT_DIR/seed_v2_lib.sh"

SEED_SERVER="${SEED_SERVER:-http://localhost:8080}"
PASSWORD="${PASSWORD:-seedv2pass}"
STAMP="$(date +%s)"

seed_log info "echo seed v2 — realistic day"
seed_log dim  "server: $SEED_SERVER"
seed_log dim  "stamp:  $STAMP (username prefix)"

# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------
# Six named personas with distinct bios + presence states so the seeded
# sidebar lights up with the full range of status colours.
USERNAMES=(riley morgan taylor jordan casey quinn)
BIOS=(
  "platform engineer · coffee enthusiast"
  "designer · likes long ferries"
  "qa lead · finds the bug you didn't write a test for"
  "pm · still convinced standup could be a slack message"
  "frontend · responsible for at least 30%% of the css"
  "backend · postgres apologist"
)
STATUSES=(online online away dnd online invisible)
TOPICS=(tech tech music gaming generic generic)

declare -A USER_ID
declare -A USER_TOKEN
declare -A USER_TOPIC

seed_log info "phase 1 — users"
for i in "${!USERNAMES[@]}"; do
  uname="${USERNAMES[$i]}_$STAMP"
  bio="${BIOS[$i]}"
  status="${STATUSES[$i]}"
  topic="${TOPICS[$i]}"
  seed_user "$uname" "$PASSWORD" "$bio" "$status"
  USER_ID["${USERNAMES[$i]}"]="$SEED_USER_ID"
  USER_TOKEN["${USERNAMES[$i]}"]="$SEED_USER_TOKEN"
  USER_TOPIC["${USERNAMES[$i]}"]="$topic"
  printf "    %-12s %s  [%s]\n" "$uname" "$SEED_USER_ID" "$status"
done

# ---------------------------------------------------------------------------
# Contacts (all-to-all)
# ---------------------------------------------------------------------------
seed_log info "phase 2 — contacts (all-to-all)"
for a in "${USERNAMES[@]}"; do
  for b in "${USERNAMES[@]}"; do
    [ "$a" = "$b" ] && continue
    seed_contact_accept "${USER_TOKEN[$a]}" "${USER_TOKEN[$b]}" "${b}_$STAMP"
  done
done

# ---------------------------------------------------------------------------
# Groups (one plaintext, one encrypted)
# ---------------------------------------------------------------------------
seed_log info "phase 3 — groups"
OWNER=riley
seed_group "${USER_TOKEN[$OWNER]}" "Daily Standup ($STAMP)" \
  "open team channel, plaintext" 0
PLAINTEXT_GROUP="$SEED_GROUP_ID"
seed_log ok "plaintext group: $PLAINTEXT_GROUP"

seed_group "${USER_TOKEN[$OWNER]}" "Secure Room ($STAMP)" \
  "encrypted team channel" 1
ENCRYPTED_GROUP="$SEED_GROUP_ID"
seed_log ok "encrypted group: $ENCRYPTED_GROUP"

# Everyone else joins both groups.
for u in "${USERNAMES[@]}"; do
  [ "$u" = "$OWNER" ] && continue
  seed_group_invite_accept "${USER_TOKEN[$OWNER]}" "${USER_TOKEN[$u]}" "$PLAINTEXT_GROUP"
  seed_group_invite_accept "${USER_TOKEN[$OWNER]}" "${USER_TOKEN[$u]}" "$ENCRYPTED_GROUP"
done

# ---------------------------------------------------------------------------
# Pairwise DMs
# ---------------------------------------------------------------------------
seed_log info "phase 4 — pairwise DMs"
TOTAL_DMS=0
# Pick a stable order of pairs.
PAIRS=(
  "riley:morgan"   "riley:taylor"   "morgan:jordan"
  "taylor:casey"   "jordan:quinn"   "casey:quinn"
)
for pair in "${PAIRS[@]}"; do
  a="${pair%%:*}"
  b="${pair##*:}"
  # 4-10 messages, alternating sender, distributed across the day.
  count=$((4 + RANDOM % 7))
  seed_log dim "  $a <-> $b — $count messages"
  for ((j=0; j<count; j++)); do
    if [ $((j % 2)) -eq 0 ]; then
      sender="$a"; recipient="$b"
    else
      sender="$b"; recipient="$a"
    fi
    topic="${USER_TOPIC[$sender]}"
    text="$(random_message_text "$topic")"
    seed_dm_message "${USER_TOKEN[$sender]}" "${USER_ID[$recipient]}" "$text"
    TOTAL_DMS=$((TOTAL_DMS + 1))
  done
done

# ---------------------------------------------------------------------------
# Group rhythm — plaintext group gets the realistic-day arc
# ---------------------------------------------------------------------------
seed_log info "phase 5 — plaintext group rhythm"
TOTAL_GROUP_MSGS=0
declare -a STANDUP_IDS=()
declare -a ASYNC_IDS=()
declare -a DECISION_IDS=()

# 08:00 — standup (5 short messages, one per person who's "online" first).
seed_log dim "  08:00 standup (5 msgs)"
STANDUP_BLURBS=(
  "morning, working on the auth refactor today"
  "design review at 11 if anyone wants to weigh in"
  "qa sweep on the new build, will post repros as i find them"
  "stakeholder sync moved to 3, fyi"
  "shipping the css token cleanup this morning"
)
for i in "${!STANDUP_BLURBS[@]}"; do
  sender="${USERNAMES[$i]}"
  seed_group_message "${USER_TOKEN[$sender]}" "$PLAINTEXT_GROUP" "${STANDUP_BLURBS[$i]}"
  [ -n "$SEED_MESSAGE_ID" ] && STANDUP_IDS+=("$SEED_MESSAGE_ID")
  TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
done

# 09:30 — async chat (12 msgs, 2-3 reply threads).
seed_log dim "  09:30 async chat (12 msgs + replies)"
for ((i=0; i<12; i++)); do
  sender="${USERNAMES[$((RANDOM % ${#USERNAMES[@]}))]}"
  topic="${USER_TOPIC[$sender]}"
  text="$(random_message_text "$topic")"
  seed_group_message "${USER_TOKEN[$sender]}" "$PLAINTEXT_GROUP" "$text"
  [ -n "$SEED_MESSAGE_ID" ] && ASYNC_IDS+=("$SEED_MESSAGE_ID")
  TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
done

# Branching: 3 reply threads, each replying to a different async parent.
if [ "${#ASYNC_IDS[@]}" -ge 3 ]; then
  parents=("${ASYNC_IDS[2]}" "${ASYNC_IDS[5]}" "${ASYNC_IDS[8]}")
  for p in "${parents[@]}"; do
    for r in 1 2; do
      sender="${USERNAMES[$((RANDOM % ${#USERNAMES[@]}))]}"
      text="$(random_message_text generic)"
      seed_group_message "${USER_TOKEN[$sender]}" "$PLAINTEXT_GROUP" \
        "$text" "$p"
      TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
    done
  done
fi

# 12:00 — lunch lull (1-2 msgs).
seed_log dim "  12:00 lunch lull (2 msgs)"
seed_group_message "${USER_TOKEN[casey]}" "$PLAINTEXT_GROUP" \
  "anyone want anything from the cafe"
TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
seed_group_message "${USER_TOKEN[quinn]}" "$PLAINTEXT_GROUP" \
  "iced americano please, owe you one"
TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))

# 14:00 — decision thread (8 msgs, 4 replies).
seed_log dim "  14:00 decision thread (8 msgs + 4 replies)"
DECISIONS=(
  "ok decision needed: do we ship the lounge fix in this patch or roll it forward?"
  "personally i'd cut a patch — the perf regression hits the most-used screen"
  "if we cut today we have to skip the icon update, that's the tradeoff"
  "icon update can wait, lounge has more user impact"
  "+1 to shipping today, qa already smoked the build"
  "what's the rollback plan if it regresses live?"
  "watchtower will pick up the previous tag in under 5 min, we've done it twice this month"
  "ok consensus — patch today, icons next week. thanks all"
)
for i in "${!DECISIONS[@]}"; do
  sender="${USERNAMES[$((i % ${#USERNAMES[@]}))]}"
  seed_group_message "${USER_TOKEN[$sender]}" "$PLAINTEXT_GROUP" "${DECISIONS[$i]}"
  [ -n "$SEED_MESSAGE_ID" ] && DECISION_IDS+=("$SEED_MESSAGE_ID")
  TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
done

# Branching: 4 replies to a mix of decision-thread parents.
if [ "${#DECISION_IDS[@]}" -ge 6 ]; then
  REPLY_TARGETS=("${DECISION_IDS[0]}" "${DECISION_IDS[2]}" "${DECISION_IDS[5]}" "${DECISION_IDS[6]}")
  REPLY_TEXTS=(
    "agree, let's call it"
    "the icons can ride the next train"
    "yeah rollback is well-rehearsed at this point"
    "we should still write that runbook though"
  )
  for i in "${!REPLY_TARGETS[@]}"; do
    sender="${USERNAMES[$(( (i + 1) % ${#USERNAMES[@]} ))]}"
    seed_group_message "${USER_TOKEN[$sender]}" "$PLAINTEXT_GROUP" \
      "${REPLY_TEXTS[$i]}" "${REPLY_TARGETS[$i]}"
    TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
  done
fi

# 17:30 — EOD updates (5 msgs).
seed_log dim "  17:30 EOD (5 msgs)"
EOD_BLURBS=(
  "shipped the auth refactor, no rollback"
  "design system PR is up, would love eyes tomorrow"
  "filed 3 bugs from the smoke pass, all p2 or below"
  "calling it, see you all tomorrow"
  "out till friday — coverage on the on-call rotation, thanks quinn"
)
for i in "${!EOD_BLURBS[@]}"; do
  sender="${USERNAMES[$i]}"
  seed_group_message "${USER_TOKEN[$sender]}" "$PLAINTEXT_GROUP" "${EOD_BLURBS[$i]}"
  TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
done

# ---------------------------------------------------------------------------
# Encrypted group — populate with realistic ciphertext-shaped strings.
# The server stores message.content verbatim; we can't drive the Signal
# Protocol from bash, so the simplest faithful approximation is to post
# strings that *look* like base64-wrapped ratchet wire so the client's
# "[Encrypted]" placeholder and the lock indicator both render. NOT real
# ciphertext — this is for UI exercise only.
# ---------------------------------------------------------------------------
seed_log info "phase 6 — encrypted group placeholders"
random_b64() {
  # Approx 120-char base64 string, no =, no newlines.
  head -c 90 /dev/urandom | base64 | tr -d '=\n' | head -c 120
}
ENCRYPTED_MSG_COUNT=8
for ((i=0; i<ENCRYPTED_MSG_COUNT; i++)); do
  sender="${USERNAMES[$((i % ${#USERNAMES[@]}))]}"
  fake_ct="$(random_b64)"
  seed_group_message "${USER_TOKEN[$sender]}" "$ENCRYPTED_GROUP" "$fake_ct"
  TOTAL_GROUP_MSGS=$((TOTAL_GROUP_MSGS + 1))
done

# ---------------------------------------------------------------------------
# Reactions
# ---------------------------------------------------------------------------
seed_log info "phase 7 — reactions"
REACTION_EMOJI=("👍" "🎉" "🚀" "❤" "👀" "🙌" "🔥" "✅" "🤔" "😂")
ALL_IDS=("${STANDUP_IDS[@]}" "${ASYNC_IDS[@]}" "${DECISION_IDS[@]}")
REACTION_COUNT=0
TARGET_REACTIONS=15
if [ "${#ALL_IDS[@]}" -gt 0 ]; then
  for ((i=0; i<TARGET_REACTIONS; i++)); do
    mid="${ALL_IDS[$((RANDOM % ${#ALL_IDS[@]}))]}"
    emoji="${REACTION_EMOJI[$((RANDOM % ${#REACTION_EMOJI[@]}))]}"
    reactor="${USERNAMES[$((RANDOM % ${#USERNAMES[@]}))]}"
    seed_reaction "${USER_TOKEN[$reactor]}" "$mid" "$emoji"
    REACTION_COUNT=$((REACTION_COUNT + 1))
  done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

==> seed v2 realistic-day complete

  users created       : ${#USERNAMES[@]}  (prefix _$STAMP, password $PASSWORD)
  plaintext group     : Daily Standup ($STAMP) = $PLAINTEXT_GROUP
  encrypted group     : Secure Room ($STAMP)  = $ENCRYPTED_GROUP
  pairwise DM threads : ${#PAIRS[@]}
  total DM messages   : $TOTAL_DMS
  total group msgs    : $TOTAL_GROUP_MSGS
  reactions seeded    : $REACTION_COUNT

  login: any of ${USERNAMES[*]}_$STAMP / $PASSWORD
EOF
