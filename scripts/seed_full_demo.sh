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
for spec in "${GROUPS[@]}"; do
  IFS='|' read -r title _ _ members_csv <<<"$spec"
  cid=${GROUP_ID[$title]}
  IFS=',' read -r -a member_arr <<<"$members_csv"
  msg_count=$((8 + RANDOM % 5))
  # Build a multi-row INSERT for one round-trip per group.
  values=""
  for i in $(seq 1 "$msg_count"); do
    sender="${member_arr[$((RANDOM % ${#member_arr[@]}))]}"
    sid=${USER_ID[$sender]}
    template="${MESSAGES[$((RANDOM % ${#MESSAGES[@]}))]}"
    # PG-escape single quotes in templates.
    body=${template//\'/\'\'}
    # Stagger created_at over the last hour, oldest first.
    offset=$((msg_count - i))
    sep=","
    [ -z "$values" ] && sep=""
    values+="$sep('$cid', '$sid', '$body', now() - (interval '1 minute' * $offset))"
  done
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
INSERT INTO messages (conversation_id, sender_id, content, created_at) VALUES $values;
SQL
  total_msgs=$((total_msgs + msg_count))
  printf "   %-16s +%d messages\n" "$title" "$msg_count"
done

cat <<EOF

==> Done!

   ${#USERS[@]} users        : ${USERS[*]}
   ${#GROUPS[@]} public groups : ${!GROUP_ID[@]}
   ${total_msgs} messages

Login credentials (any user):
   password: $PASSWORD

Re-run with FORCE=1 to wipe and re-seed.
EOF
