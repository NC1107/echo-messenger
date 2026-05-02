#!/usr/bin/env bash
# Seed Echo Messenger with users, contacts, public groups, group memberships,
# and demo messages so the app has something to look at on first run.
#
# Users are registered via the REST API (so passwords are properly Argon2id-
# hashed and prekeys land via the normal flow). Contacts, group conversations,
# memberships, and messages are inserted directly via psql to bypass the WS +
# E2E-encryption requirements that would otherwise complicate seed data.
#
# All seeded groups are created with is_encrypted=false so the inserted plain
# `content` strings render as-is in the client. Real DMs are auto-encrypted
# end-to-end by design (#591) and are intentionally NOT seeded here -- when you
# want to exercise DM flows, use two real client sessions.
#
# Usage:
#   ./scripts/seed_full_demo.sh                        # localhost defaults
#   SERVER_URL=http://localhost:8080 \
#     DB_URL=postgres://echo:devpass@localhost:5432/echo_dev \
#     ./scripts/seed_full_demo.sh
#
# Env overrides:
#   SERVER_URL  Echo server URL (default http://localhost:8080)
#   DB_URL      Postgres connection string
#               (default postgres://echo:devpass@localhost:5432/echo_dev)
#   PASSWORD    Demo password for every seeded user (default demopass123)
#   FORCE       1 = wipe seeded users/groups before re-seeding
#
# Reruns are idempotent. Existing users login instead of register; groups
# upsert by title; messages append (so re-running grows the timeline).

set -euo pipefail

SERVER_URL="${SERVER_URL:-http://localhost:8080}"
DB_URL="${DB_URL:-postgres://echo:devpass@localhost:5432/echo_dev}"
PASSWORD="${PASSWORD:-demopass123}"
FORCE="${FORCE:-0}"

# ---- Dependency checks ------------------------------------------------------
for cmd in curl jq psql; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but not on PATH" >&2
    exit 1
  fi
done

# ---- Demo cast --------------------------------------------------------------
USERS=(alice bob charlie diana eve frank grace henry)

# group_title|description|owner|members(comma)
GROUPS=(
  "Tech Talk|Programming, gadgets, and infra nerdery|alice|alice,bob,charlie,diana,eve"
  "Gaming Lounge|LFG, reviews, and esports|bob|bob,charlie,frank,grace,henry"
  "Music Corner|Share tracks and discover artists|charlie|alice,charlie,diana,grace"
  "Movie Club|Watch parties and reviews|diana|diana,eve,frank,henry"
  "Random Chat|Off-topic, memes, and hangout|alice|alice,bob,charlie,diana,eve,frank,grace,henry"
  "Book Worms|Reading lists and literary discussion|grace|alice,grace,henry"
)

# Pool of message templates. {user} is substituted at insert time so the
# message reads naturally regardless of who the sender ends up being.
MESSAGES=(
  "hey everyone, what's up"
  "anyone tried the new beta build?"
  "lol that's wild"
  "sounds good"
  "I'll check it out tonight"
  "any recommendations for the weekend?"
  "did you see the announcement?"
  "ship it"
  "+1 to that"
  "we should hop on voice later"
  "fixed it locally, pushing now"
  "ngl that was a great call"
  "anyone else seeing this issue?"
  "got it working, thanks"
  "lunch in 10?"
  "just finished a fun deep dive on this"
  "this is the way"
  "back from a walk, what'd I miss"
  "tldr: it works"
  "absolute classic"
)

echo "==> Seeding Echo demo data"
echo "    server: $SERVER_URL"
echo "    db:     ${DB_URL%%@*}@***"
echo "    users:  ${USERS[*]}"
echo "    groups: ${#GROUPS[@]} public groups"

# ---- Server reachability ----------------------------------------------------
if ! curl -sf "$SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "ERROR: server not reachable at $SERVER_URL/api/health" >&2
  echo "       start it with ./scripts/run.sh and try again" >&2
  exit 1
fi

# ---- Optional wipe ----------------------------------------------------------
if [ "$FORCE" = "1" ]; then
  echo "==> FORCE=1: wiping previously-seeded users, groups, and messages"
  psql "$DB_URL" -v ON_ERROR_STOP=1 <<SQL >/dev/null
WITH demo AS (
  SELECT id FROM users WHERE username = ANY(ARRAY[$(printf "'%s'," "${USERS[@]}" | sed 's/,$//')])
)
DELETE FROM messages       WHERE sender_id      IN (SELECT id FROM demo);
DELETE FROM conversation_members WHERE user_id  IN (SELECT id FROM demo);
DELETE FROM conversations  WHERE id IN (
  SELECT id FROM conversations WHERE kind = 'group' AND title = ANY(ARRAY[$(printf "'%s'," "${GROUPS[@]%%|*}" | sed 's/,$//')])
);
DELETE FROM contacts       WHERE requester_id   IN (SELECT id FROM demo)
                              OR target_id      IN (SELECT id FROM demo);
DELETE FROM users          WHERE id             IN (SELECT id FROM demo);
SQL
fi

# ---- Phase 1: register users via REST --------------------------------------
declare -A USER_ID
declare -A USER_TOKEN
for u in "${USERS[@]}"; do
  resp=$(curl -s -X POST "$SERVER_URL/api/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}")
  if [ "$(jq -r '.access_token // empty' <<<"$resp")" = "" ]; then
    # Already exists -> login
    resp=$(curl -sf -X POST "$SERVER_URL/api/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}")
  fi
  uid=$(jq -r '.user_id' <<<"$resp")
  tok=$(jq -r '.access_token' <<<"$resp")
  if [ "$uid" = "null" ] || [ -z "$uid" ]; then
    echo "ERROR: failed to register/login $u: $resp" >&2
    exit 1
  fi
  USER_ID[$u]=$uid
  USER_TOKEN[$u]=$tok
  printf "   user %-8s %s\n" "$u" "$uid"
done

# ---- Phase 2: contacts (everyone with everyone) ----------------------------
echo "==> Linking contacts (all-to-all, accepted)"
for a in "${USERS[@]}"; do
  for b in "${USERS[@]}"; do
    [ "$a" = "$b" ] && continue
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO contacts (requester_id, target_id, status)
VALUES ('${USER_ID[$a]}', '${USER_ID[$b]}', 'accepted')
ON CONFLICT (requester_id, target_id) DO UPDATE SET status = 'accepted', updated_at = now();
SQL
  done
done

# ---- Phase 3: groups (idempotent upsert by title) --------------------------
echo "==> Creating ${#GROUPS[@]} public groups"
declare -A GROUP_ID
for spec in "${GROUPS[@]}"; do
  IFS='|' read -r title desc owner members_csv <<<"$spec"
  oid=${USER_ID[$owner]}
  cid=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -At <<SQL
WITH ins AS (
  INSERT INTO conversations (kind, title, description, is_public, is_encrypted)
  SELECT 'group', '$title', '$desc', true, false
  WHERE NOT EXISTS (SELECT 1 FROM conversations WHERE kind = 'group' AND title = '$title')
  RETURNING id
)
SELECT id FROM ins
UNION ALL
SELECT id FROM conversations WHERE kind = 'group' AND title = '$title'
LIMIT 1;
SQL
)
  if [ -z "$cid" ]; then
    echo "ERROR: failed to upsert group '$title'" >&2
    exit 1
  fi
  GROUP_ID[$title]=$cid
  printf "   group %-16s %s (owner=%s)\n" "$title" "$cid" "$owner"

  # Owner first (admin role).
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO conversation_members (conversation_id, user_id, role, is_removed)
VALUES ('$cid', '$oid', 'admin', false)
ON CONFLICT (conversation_id, user_id) DO UPDATE SET role = 'admin', is_removed = false, removed_at = NULL;
SQL

  # Other members.
  IFS=',' read -r -a member_arr <<<"$members_csv"
  for m in "${member_arr[@]}"; do
    [ "$m" = "$owner" ] && continue
    mid=${USER_ID[$m]}
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO conversation_members (conversation_id, user_id, role, is_removed)
VALUES ('$cid', '$mid', 'member', false)
ON CONFLICT (conversation_id, user_id) DO UPDATE SET is_removed = false, removed_at = NULL;
SQL
  done

  # Refresh denormalized member_count to match active members (#701).
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
UPDATE conversations SET member_count = (
  SELECT COUNT(*) FROM conversation_members
  WHERE conversation_id = '$cid' AND is_removed = false
) WHERE id = '$cid';
SQL
done

# ---- Phase 4: messages (8-12 per group, time-ordered) ----------------------
echo "==> Seeding messages"
total_msgs=0
total_replies=0
total_pins=0
total_reactions=0
declare -a UPLOAD_DIR_CANDIDATES=("./uploads" "./apps/server/uploads")
UPLOADS_DIR=""
for cand in "${UPLOAD_DIR_CANDIDATES[@]}"; do
  if [ -d "$cand" ] && [ -w "$cand" ]; then UPLOADS_DIR="$cand"; break; fi
done
EMOJIS=("👍" "❤️" "😂" "🔥" "🎉" "👀" "🚀" "💯" "🤔" "✨")

for spec in "${GROUPS[@]}"; do
  IFS='|' read -r title _ owner members_csv <<<"$spec"
  cid=${GROUP_ID[$title]}
  oid=${USER_ID[$owner]}
  IFS=',' read -r -a member_arr <<<"$members_csv"
  msg_count=$((8 + RANDOM % 5))

  # Build a multi-row INSERT for one round-trip per group, return new ids.
  values=""
  declare -a senders=()
  for i in $(seq 1 "$msg_count"); do
    sender="${member_arr[$((RANDOM % ${#member_arr[@]}))]}"
    sid=${USER_ID[$sender]}
    senders+=("$sid")
    template="${MESSAGES[$((RANDOM % ${#MESSAGES[@]}))]}"
    body=${template//\'/\'\'}
    offset=$((msg_count - i))
    sep=","; [ -z "$values" ] && sep=""
    values+="$sep('$cid', '$sid', '$body', now() - (interval '1 minute' * $offset))"
  done
  mapfile -t MSG_IDS < <(psql "$DB_URL" -v ON_ERROR_STOP=1 -At <<SQL
INSERT INTO messages (conversation_id, sender_id, content, created_at)
VALUES $values
RETURNING id;
SQL
)
  total_msgs=$((total_msgs + msg_count))

  # 4a. Replies: pick 1-2 messages and have a different sender reply to one
  # of the earliest messages, threaded.
  if [ ${#MSG_IDS[@]} -ge 4 ]; then
    parent_idx=1
    parent_id="${MSG_IDS[$parent_idx]}"
    reply_sender="${member_arr[$((RANDOM % ${#member_arr[@]}))]}"
    reply_sid=${USER_ID[$reply_sender]}
    reply_body="${MESSAGES[$((RANDOM % ${#MESSAGES[@]}))]}"
    reply_body=${reply_body//\'/\'\'}
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO messages (conversation_id, sender_id, content, reply_to_id, created_at)
VALUES ('$cid', '$reply_sid', '$reply_body', '$parent_id', now() - interval '30 seconds');
SQL
    total_replies=$((total_replies + 1))
    total_msgs=$((total_msgs + 1))
  fi

  # 4b. Pin: pin the second message (a slightly older, more interesting one).
  if [ ${#MSG_IDS[@]} -ge 2 ]; then
    pin_id="${MSG_IDS[1]}"
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
UPDATE messages SET pinned_at = now(), pinned_by_id = '$oid' WHERE id = '$pin_id';
SQL
    total_pins=$((total_pins + 1))
  fi

  # 4c. Reactions: 5-9 reactions distributed over a few messages.
  rx_count=$((5 + RANDOM % 5))
  rx_values=""
  for r in $(seq 1 "$rx_count"); do
    target_idx=$((RANDOM % ${#MSG_IDS[@]}))
    target_id="${MSG_IDS[$target_idx]}"
    reactor="${member_arr[$((RANDOM % ${#member_arr[@]}))]}"
    reactor_id=${USER_ID[$reactor]}
    emoji="${EMOJIS[$((RANDOM % ${#EMOJIS[@]}))]}"
    sep=","; [ -z "$rx_values" ] && sep=""
    rx_values+="$sep('$target_id', '$reactor_id', '$emoji')"
  done
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO reactions (message_id, user_id, emoji)
VALUES $rx_values
ON CONFLICT (message_id, user_id, emoji) DO NOTHING;
SQL
  # Count actual unique reactions (some collisions on (message,user,emoji)).
  applied=$(psql "$DB_URL" -At -v ON_ERROR_STOP=1 <<SQL
SELECT COUNT(*) FROM reactions
WHERE message_id IN ($(printf "'%s'," "${MSG_IDS[@]}" | sed 's/,$//'));
SQL
)
  total_reactions=$((total_reactions + ${applied:-0}))

  printf "   %-16s +%d msgs (+1 reply, +1 pin, +%s reactions)\n" \
    "$title" "$msg_count" "${applied:-0}"
done

# ---- Phase 5: group avatars (icon_url -> stable identicon) -----------------
echo "==> Setting group icons (dicebear identicons)"
for spec in "${GROUPS[@]}"; do
  IFS='|' read -r title _ _ _ <<<"$spec"
  cid=${GROUP_ID[$title]}
  # URL-encode the title for the dicebear seed.
  seed=$(printf '%s' "$title" | jq -sRr @uri)
  icon="https://api.dicebear.com/7.x/identicon/svg?seed=$seed&backgroundColor=transparent"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
UPDATE conversations SET icon_url = '$icon' WHERE id = '$cid';
SQL
done

# ---- Phase 6: attachment (one image-message per group) ---------------------
# Drops a 1x1 transparent PNG into the server's uploads dir, registers a
# media row, and posts a message whose content links to the media.  The
# Flutter client treats /api/media/<uuid> URLs in content as attachments
# (apps/client/lib/src/widgets/message_item.dart:381).
total_attachments=0
if [ -n "$UPLOADS_DIR" ]; then
  echo "==> Seeding attachments (uploads dir: $UPLOADS_DIR)"
  PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
  for spec in "${GROUPS[@]}"; do
    IFS='|' read -r title _ _ members_csv <<<"$spec"
    cid=${GROUP_ID[$title]}
    IFS=',' read -r -a member_arr <<<"$members_csv"
    sender="${member_arr[$((RANDOM % ${#member_arr[@]}))]}"
    sid=${USER_ID[$sender]}
    media_uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    media_path="$UPLOADS_DIR/${media_uuid}.png"
    printf '%s' "$PNG_B64" | base64 -d > "$media_path"
    size=$(stat -c%s "$media_path" 2>/dev/null || stat -f%z "$media_path")
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO media (id, uploader_id, filename, mime_type, size_bytes, conversation_id)
VALUES ('$media_uuid', '$sid', 'demo.png', 'image/png', $size, '$cid');

INSERT INTO messages (conversation_id, sender_id, content, created_at)
VALUES ('$cid', '$sid', '/api/media/$media_uuid', now() - interval '5 seconds');
SQL
    total_attachments=$((total_attachments + 1))
    total_msgs=$((total_msgs + 1))
  done
else
  echo "==> Skipping attachments (no writable ./uploads dir found; run from repo root or apps/server/)"
fi

cat <<EOF

==> Done!

   ${#USERS[@]} users         : ${USERS[*]}
   ${#GROUPS[@]} public groups: ${!GROUP_ID[@]}
   ${total_msgs} messages
   ${total_replies} reply chains
   ${total_pins} pinned messages
   ${total_reactions} reactions
   ${total_attachments} attachments

Login credentials (any user):
   password: $PASSWORD

Re-run with FORCE=1 to wipe and re-seed.
EOF
