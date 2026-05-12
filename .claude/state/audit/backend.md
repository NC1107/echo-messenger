# Backend Audit (2026-05-09)

Targeted single-pass audit. Excludes items in #783. Focus: hot files (message_service, db/messages, routes/messages, routes/media, routes/groups), fresh code (1b53277 mention persistence), background tasks, transactions, and offline-replay correctness.

### Finding 1: Multi-device offline siblings lose messages once any device receives them
- **File**: apps/server/src/ws/message_service.rs:979
- **Severity**: critical
- **Description**: After fanout, `send_delivery_confirmation` calls `db::messages::mark_delivered(&[stored_id])` which sets the global `messages.delivered = true` as soon as ANY recipient device enqueues the message. The undelivered-replay query in `db::messages::get_undelivered` (apps/server/src/db/messages.rs:335) filters with `m.delivered = false`, so a recipient user's OFFLINE sibling devices never see the message on reconnect even though their per-device ciphertext exists in `message_device_contents` and the per-device ledger (`message_deliveries`) has no entry for that device. This silently drops messages on multi-device accounts whenever at least one device is online at send time. The per-device ledger comments and the undecryptable branch (`mark_delivered` is intentionally skipped there) suggest the original intent was to keep `delivered=false` until all recipient devices were covered, but the online-fanout path bypasses that.
- **Code**:
```rust
if any_delivered {
    send_delivery_confirmation(state, sender_id, sender_device_id, stored_id, conv_id).await;
}
```
- **Fix**: Stop using the global `messages.delivered` flag as the offline-replay gate. Drop the `m.delivered = false` predicate from `get_undelivered` and rely solely on `NOT EXISTS (... message_deliveries ...)`. Additionally, in `fanout_message` after each successful per-device enqueue, call `mark_device_delivered_batch` for the `(message_id, recipient_user_id, device_id)` triples that were actually accepted by the hub so the ledger is the single source of truth (mirrors the offline-replay path which already does this).
- **Effort**: medium

### Finding 2: Invite-token use_count and expiry not re-validated inside the consume transaction
- **File**: apps/server/src/db/groups.rs:838
- **Severity**: high
- **Description**: `accept_invite_token` opens a tx and `SELECT ... FOR UPDATE` on the token row, but the SELECT only pulls `conversation_id` — it does NOT re-check `expires_at` or `max_uses` inside the transaction. The HTTP handler (`accept_invite` in routes/groups.rs:1238) checks both before calling, which is a textbook TOCTOU window: N concurrent acceptors all observe `use_count < max_uses` at the HTTP layer, all enter the tx, and `use_count` is incremented N times past the cap. Same bypass works for an invite that expires between the check and the tx.
- **Code**:
```rust
let row: (Uuid,) = sqlx::query_as(
    "SELECT conversation_id FROM group_invite_tokens WHERE token = $1 FOR UPDATE",
)
```
- **Fix**: Pull `expires_at`, `max_uses`, `use_count` in the locked SELECT and re-validate inside the tx; return `Err(sqlx::Error::RowNotFound)` (or a typed error) when expired/exhausted so the caller can map to 4xx. Increment `use_count` conditionally (`WHERE use_count < max_uses OR max_uses IS NULL`) and check `rows_affected`.
- **Effort**: small

### Finding 3: Mentions ignore the sender-must-be-a-member constraint
- **File**: apps/server/src/db/mentions.rs:116
- **Severity**: medium
- **Description**: `extract_and_persist` is invoked from `store_and_confirm` after `store_message` succeeds, but it never validates that `sender_id` is a member of `conversation_id` and never scopes the `@everyone`/`@here` resolution against the sender's eligibility. The send-path *does* check membership in `resolve_conversation`, but the mentions module is also called by `insert_system_message` paths in the future and exposes a primitive that trusts callers. More concretely: if a future caller routes a message into a conversation while the sender row is mid-flight (e.g. add_member followed by their first message), the mentions table can transiently contain rows for `@everyone` that reflect a roster the sender hasn't fully joined yet. Lower-severity issue: the function fetches `conversation_members` for `@everyone`/`@here` without a `LIMIT` — large public groups with tens of thousands of members will burst-insert one row per member per message containing `@everyone`. No rate limiting on broadcast keywords means a single 5-character message can blow up the table.
- **Code**:
```rust
"SELECT cm.user_id FROM conversation_members cm \
 WHERE cm.conversation_id = $1 AND cm.is_removed = false",
```
- **Fix**: (1) Cap `@everyone`/`@here` mention insertion to a sane group-size threshold (e.g. 200 members) and skip persisting otherwise — for larger groups, mentions become unread-aggregate signals at the conversation level rather than per-row. (2) Restrict broadcast keywords to admin/owner senders (mirrors Discord/Slack norms) by passing the sender role into `extract_and_persist`. (3) Treat `@here` distinct from `@everyone` for storage: `@here` should only persist mentions for currently-online members so the badge matches the suppress-offline-push semantic the fanout already implements.
- **Effort**: medium

### Finding 4: list_conversations CTE silently drops mentions on system messages and counts mentions in deleted-channel messages
- **File**: apps/server/src/routes/messages.rs:224
- **Severity**: medium
- **Description**: The `mention_cte` joins `mentions` -> `messages` filtering only on `deleted_at IS NULL` and `created_at > last_read_at`. It does NOT filter on `m3.channel_id` (so mentions in a deleted channel still count after the channel row is gone — `messages.channel_id` is `ON DELETE SET NULL`, leaving orphan rows that resurface in unread counts), nor does it exclude system-message sentinels (content prefix `__system__:`) which pass through `extract_and_persist` only because the send-path skips it for `__system__:` content (it doesn't — `insert_system_message` bypasses `store_and_confirm` so mentions table sees no system rows). The first issue is the real one: a deleted-channel message stays in `messages` with `channel_id=NULL`, the user is still a member, and `mention_count` ticks up forever for mentions in a channel they can no longer access.
- **Code**:
```rust
mention_cte AS ( \
    SELECT m3.conversation_id, COUNT(*) AS mention_count \
    FROM messages m3 \
    JOIN mentions mt ON mt.message_id = m3.id \
    ...
    AND m3.created_at > COALESCE(rc2.last_read_at, '1970-01-01'::timestamptz) \
    GROUP BY m3.conversation_id \
)
```
- **Fix**: When a channel is deleted, soft-delete its messages (set `deleted_at`) instead of relying on `ON DELETE SET NULL` of `channel_id`, OR add `AND (m3.channel_id IS NULL OR EXISTS (SELECT 1 FROM channels c WHERE c.id = m3.channel_id))` to the mention CTE. Same applies to `unread_cte`.
- **Effort**: small

### Finding 5: store_device_contents builds SQL via string concatenation — quadratic alloc and harder to maintain
- **File**: apps/server/src/db/messages.rs:778
- **Severity**: low
- **Description**: For every message with N recipient devices, the code allocates a fresh `String`, push-formats `($1, $X, $Y, $Z)` per row, then binds. For a 100-member encrypted group with 3 devices each (300 rows), this is 300 `format!` allocations. Postgres protocol uses positional parameters so this is correct, but the same SHAPE can be rewritten as a single `INSERT ... SELECT * FROM UNNEST($1::uuid[], $2::uuid[], $3::int[], $4::text[])` — which `mark_device_delivered_batch` (line 383) already uses successfully for a similar pattern. Consistency matters: the two batch paths do different things, and the slow path is on the hot send route.
- **Code**:
```rust
query.push_str(&format!(
    "($1, ${}, ${}, ${})",
    param_idx, param_idx + 1, param_idx + 2
));
```
- **Fix**: Replace the dynamic SQL with `INSERT INTO message_device_contents (message_id, recipient_user_id, device_id, content) SELECT $1, uid, did, ct FROM UNNEST($2::uuid[], $3::int[], $4::text[]) AS t(uid, did, ct) ON CONFLICT DO NOTHING`. Single bind site, single allocation, identical semantics.
- **Effort**: small

### Finding 6: Heartbeat ping_task races with hub unregister and may panic-leak on send_to_device(Ping)
- **File**: apps/server/src/ws/handler.rs:230
- **Severity**: medium
- **Description**: The 30-second heartbeat task sends both a `Ping` and a JSON `heartbeat`. It only breaks when the JSON heartbeat send returns false. The Ping send result is ignored; if the device is unregistered between the two calls (recv_loop terminating), the JSON send returns false on the SECOND iteration, not the first — meaning one extra Ping fires after the receiver is gone. More importantly, the loop also allocates `r#"{"type":"heartbeat"}"#.to_string()` every tick instead of holding a `WsMessage::Text` (Bytes-backed) once and cloning. Both issues are minor on their own but the unbounded-tick-after-disconnect hides metric drift: the Hub's `try_send_tracked` will log Closed every 30s for as long as the task hasn't observed the failure.
- **Code**:
```rust
ping_hub.send_to_device(&ping_user_id, ping_device_id, WsMessage::Ping(vec![].into()));
let hb = r#"{"type":"heartbeat"}"#.to_string();
if !ping_hub.send_to_device(&ping_user_id, ping_device_id, WsMessage::Text(hb.into())) {
    break;
}
```
- **Fix**: (1) Break on Ping failure as well: `if !ping_hub.send_to_device(... Ping ...) { break; }`. (2) Hoist the JSON `WsMessage::Text` out of the loop. (3) Already-correct: `ping_task.abort()` after select! ensures cleanup.
- **Effort**: small

### Finding 7: Avatar uploads buffer the full body before size check
- **File**: apps/server/src/routes/users.rs:640
- **Severity**: medium
- **Description**: `field.bytes().await` reads the entire multipart field into RAM before the `data.len() > MAX_AVATAR_SIZE` check. Same pattern in `routes/groups.rs:967` for group avatars. Axum's default body limit is 2MB, which matches the avatar cap, but the user-routes router does NOT install a `DefaultBodyLimit` (only `media_routes` does) so the actual ceiling depends on Axum's default — which since axum 0.7 defaults to 2MB, but is still implicit. If a future refactor raises the body limit globally, the avatar handler silently buffers the full upload. The streaming `stream_field_to_temp` in `routes/media.rs` shows the right pattern.
- **Code**:
```rust
let data = field
    .bytes()
    .await
    .map_err(|e| AppError::bad_request(format!("Failed to read avatar data: {e}")))?;
if data.len() > MAX_AVATAR_SIZE { ... }
```
- **Fix**: Either (a) explicitly attach `.layer(DefaultBodyLimit::max(MAX_AVATAR_SIZE * 2))` to the user/group avatar routes, or (b) refactor to stream like media `stream_field_to_temp` and enforce the cap incrementally. Option (a) is the small fix; option (b) is the consistent fix.
- **Effort**: small

### Finding 8: cleanup_empty_groups runs an unbounded scan against conversations with NOT IN subquery
- **File**: apps/server/src/main.rs:212
- **Severity**: medium
- **Description**: The empty-group reaper runs every 5 minutes with `id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)`. The `conversation_members` table grows linearly with users-and-groups; `NOT IN` against a column that is never NULL is fine in Postgres but the planner cannot use an index efficiently for this anti-join shape. There is no `LIMIT` and no time predicate, so on an instance with thousands of groups this iterates everything every 5 minutes and serially calls `delete_group_dependents` (which itself is a 9-statement transaction). On startup with a large dataset this is a thundering herd hitting the DB right after the pool is created. Also note: with the `is_removed = false` soft-delete column on `conversation_members`, this query already counts soft-removed rows as "members present" — meaning a group that has been fully soft-removed will NEVER be reaped because all rows are still in `conversation_members` with `is_removed = true`.
- **Code**:
```rust
"SELECT id FROM conversations WHERE kind = 'group' \
 AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)",
```
- **Fix**: Switch to a `NOT EXISTS (SELECT 1 FROM conversation_members cm WHERE cm.conversation_id = conversations.id AND cm.is_removed = false)` form, add a `LIMIT 100` and run more often, and use `conversations.member_count = 0` (the materialized counter from migration 20260501100000) as a fast pre-filter to skip non-empty groups entirely.
- **Effort**: small

### Finding 9: Per-device ciphertext from blocked recipients is still persisted, leaking metadata to blocker on unblock
- **File**: apps/server/src/ws/message_service.rs:451
- **Severity**: low
- **Description**: `store_and_confirm` writes per-device ciphertexts into `message_device_contents` for every entry in `recipient_device_contents`, including recipients who have blocked the sender. The fanout step later filters by `db::contacts::get_blockers_of` so the message isn't delivered live, but the row sits in the DB indefinitely. Two consequences: (1) when the recipient unblocks, on next reconnect they receive a backlog of messages from the period they were blocked — usually undesired, and a privacy vector (the blocker can verify they were unblocked by sending a probe message and watching for delivery acks); (2) wasted storage on encrypted DMs since the ciphertext rows are large. The ledger update similarly does not run for blocked recipients so `get_undelivered` will keep returning them.
- **Code**:
```rust
let entries: Vec<(Uuid, i32, &str)> = rdc
    .iter()
    .filter_map(|(uid_str, devices)| {
        let recipient_id = Uuid::parse_str(uid_str).ok()?;
        Some((recipient_id, devices))
    })
```
- **Fix**: Move the blocker lookup (currently in `fanout_message`) ahead of `store_and_confirm` and strip blocked recipients from `recipient_device_contents` before storage. Bonus: skips storage cost for blocked devices entirely.
- **Effort**: small

### Finding 10: search_messages_global query has no min-length floor — empty/short tsquery scans every conversation row
- **File**: apps/server/src/routes/messages.rs:622
- **Severity**: low
- **Description**: `search_messages_global` rejects a fully empty trimmed query but accepts a single character ("a"). `plainto_tsquery('english', 'a')` produces an empty tsquery (English stopword removal), and Postgres' GIN index returns no rows in that case; the planner still has to fan out joins across `conversation_members` for every conversation the user belongs to. There's no per-user QPS limit either. A user with 500 group memberships querying repeatedly with single-character or stopword-only strings will burn CPU on the join. Additionally, `search_messages` (per-conversation) at line 595 has identical pattern, no min-length floor and no `params.q.trim()` — and this one accepts whitespace-only.
- **Code**:
```rust
let q = params.q.trim();
if q.is_empty() {
    return Err(AppError::bad_request("Search query cannot be empty"));
}
```
- **Fix**: Require at least 3 characters AND verify `plainto_tsquery` produces a non-empty result before issuing the query (`SELECT plainto_tsquery('english', $1) <> ''::tsquery`); reject as 400 otherwise. Apply identical validation to per-conversation `search_messages`.
- **Effort**: small

### Finding 11: MessageDto duplicates every field with two names — public API contract rot
- **File**: apps/server/src/routes/messages.rs:104
- **Severity**: low
- **Description**: `MessageDto` exposes both `id`/`message_id`, `sender_id`/`from_user_id`, `sender_username`/`from_username` for the same underlying value. The struct comment and CLAUDE.md don't explain why both shapes exist. This was almost certainly transitional during the WS-event-shape -> REST-shape consolidation, but it doubles the JSON wire size of every history fetch (the largest payload in the app) and locks the server into supporting both names forever for clients. The thread-replies endpoint (`get_thread_replies`) skirts this entirely by returning `db::messages::MessageWithSender` directly, so already there are TWO message-shape contracts on this API: one for `/api/messages/:id` (DTO with duplicate fields) and one for `/api/messages/:id/replies` (raw FromRow with `sender_id`/`sender_username`). Clients have to handle both.
- **Code**:
```rust
pub id: Uuid,
pub message_id: Uuid,
pub conversation_id: Uuid,
...
pub sender_id: Uuid,
pub from_user_id: Uuid,
```
- **Fix**: Pick one shape (recommend `id`/`sender_id`/`sender_username` since the DB rows already use that), audit Dart client to find the actual field names referenced, and delete the duplicates with a deprecation note in the changelog. As a stopgap, normalize `get_thread_replies` to return `MessageDto` so both endpoints agree.
- **Effort**: medium

### Finding 12: Thread-replies endpoint trusts the parent message's deleted_at filter but then leaks reply content from soft-deleted parents
- **File**: apps/server/src/routes/messages.rs:526
- **Severity**: low
- **Description**: `get_thread_replies` looks up the parent with `WHERE id = $1 AND deleted_at IS NULL` (line 527) — so when a parent is soft-deleted, the endpoint returns 400 "Message not found", which is intended. BUT `db::messages::get_thread_replies` at db/messages.rs:902 fetches replies by `WHERE m.reply_to_id = $1 AND m.conversation_id = $2 AND m.deleted_at IS NULL`. After the parent is soft-deleted, the route blocks; before, replies are returned with `reply_to_content` and `reply_to_username` joined from the (still alive) parent. Once the parent is soft-deleted, the route returns 400 globally — but those replies are still indexed and reachable via `get_messages` on the conversation (which has no awareness of "this message was a reply to a deleted parent"). The reply rows still carry `reply_to_id` pointing at a deleted parent, and `get_messages` LEFT JOIN at db/messages.rs:239 doesn't filter `rm.deleted_at IS NULL` on the parent, so soft-deleted parent content STILL appears in the `reply_to_content` column of every reply.
- **Code**:
```rust
LEFT JOIN messages rm ON rm.id = m.reply_to_id AND rm.conversation_id = m.conversation_id \
LEFT JOIN users ru ON ru.id = rm.sender_id \
```
- **Fix**: Add `AND rm.deleted_at IS NULL` to the LEFT JOIN on `messages rm` in `get_messages`, `get_thread_replies`, and `search_messages`. This causes `reply_to_content` and `reply_to_username` to come back NULL for replies whose parent was soft-deleted, which the client already handles (the timeline renders the standard "message deleted" placeholder for null reply context).
- **Effort**: small
