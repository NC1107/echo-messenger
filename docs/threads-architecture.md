# Threads Architecture: Slack-Style Side-Pane Threads for Echo

Status: design proposal, not yet implemented.
Scope: documentation only — no code in this repo changes as part of writing this doc.

This document analyses what it would take to evolve Echo's current `reply_to_id`
chain into Slack-style threads where threaded replies live in a side pane and
are absent from the main channel timeline by default.

---

## 1. Slack's actual model

In Slack, every message has a `ts` (timestamp ID). Threaded replies carry an
additional `thread_ts` pointing at the *root* of the thread — not the
immediate parent. Slack's tree is intentionally flat: every reply hangs off
the root, there's no nested-reply tree. Replies are excluded from the main
channel timeline by default. A sender can tick "Also send to channel" at
compose time, which duplicates the reply into the main channel as a second
quoting message; the canonical row still lives in the thread. The root
message tracks `reply_count`, `latest_reply`, and `reply_users`.

Threads are *not* separate channels — they share the parent's membership,
encryption, retention, permissions, and pin state. The thread pane is a UI
construct over a server-side filter, not a new conversational primitive.
Unread state is tracked per-thread separately from the channel.

---

## 2. Echo's current state (concrete)

- **Schema** (`apps/server/migrations/20250101000000_baseline.sql` line 342):
  `messages.reply_to_id UUID NULL REFERENCES messages(id) ON DELETE SET NULL`.
  Single column, points at the *immediate* parent. No `thread_root_id`. The
  partial index `idx_messages_reply_to` exists on `reply_to_id IS NOT NULL`
  and is reinforced by `20260423000000_reply_count_index.sql` for the
  `reply_count` correlated subqueries used by history loads
  (`apps/server/src/db/messages.rs` lines 245–250).
- **Fanout** (`apps/server/src/ws/message_service/fanout.rs`,
  `fanout_message`): every message in a conversation is fanned out to every
  member who isn't blocked or the sender. `reply_to_id` is metadata that
  rides on the `ServerMessage::NewMessage` frame (lines 39, 58, 113) — it
  doesn't change routing at all. A reply is delivered to the channel exactly
  the way a top-level message is.
- **Server-side thread surfacing**: `get_thread_replies` already exists
  (`apps/server/src/db/messages.rs` line 964) and is wired to
  `GET /api/messages/:message_id/replies` (`apps/server/src/routes/messages.rs`
  line 515). History queries also surface `reply_count` and
  `last_reply_snippet` per row (`get_messages` lines 238–256).
- **Client model** (`apps/client/lib/src/models/chat_message.dart` lines 52–62):
  `replyToId`, `replyToContent`, `replyToUsername`, `replyCount`,
  `latestReplyPreview`. No `threadRootId`.
- **ThreadViewPanel** (`apps/client/lib/src/widgets/thread_view_panel.dart`
  line 147): the thread is "imaginary" — the panel queries the local
  `chatProvider` cache and filters `messages.where((m) => m.replyToId ==
  parent.id)`. There is no thread identifier; the panel groups by parent
  on the client.
- **ChatMessageList** (`apps/client/lib/src/widgets/chat_panel/chat_message_list.dart`):
  no filter against threads at all. Every message the provider knows about
  is rendered in the main stream, which is why the main timeline is noisy
  in an active thread.
- **Optimistic reply-count bookkeeping** (`apps/client/lib/src/providers/chat/chat_provider.dart`
  lines 89–199): the client increments/decrements `replyCount` on the parent
  when a reply is added / fails / is retried. Solid infra to build on.

The summary: Echo today has *inline replies with a thread view*, not threads.
The replies are stored, fanned out, and rendered identically to top-level
messages; the only "threading" is a client-side filter inside one widget.

---

## 3. What changes to ship "Stage 1" (Slack-equivalent, default off)

Each bullet names the file(s) and a one-line summary of the edit. None of
these are written yet — this is a forward design.

- **Schema migration** — new file `apps/server/migrations/2026XXXXXXXXXX_thread_root_id.sql`:
  add `messages.thread_root_id UUID NULL REFERENCES messages(id) ON DELETE SET NULL`.
  Critically `thread_root_id ≠ reply_to_id`: the former is the root of the
  thread tree (immutable for the life of the thread); the latter is the
  immediate quoted parent (used by `ReplyQuote` rendering). Index
  `idx_messages_thread_root ON messages (conversation_id, thread_root_id)
  WHERE thread_root_id IS NOT NULL AND deleted_at IS NULL`.
- **`store_message`** (`apps/server/src/db/messages.rs` line 177): accept
  an optional `thread_root_id`. When the caller flags "reply in thread",
  resolve it to the parent's own `thread_root_id` if set, else the
  parent's `id`. One extra `SELECT` inside the existing CTE.
- **`get_messages`** (`apps/server/src/db/messages.rs` line 230): add
  `AND m.thread_root_id IS NULL` to the WHERE clause. Thread replies
  disappear from the channel timeline.
- **`get_thread_replies`** (`apps/server/src/db/messages.rs` line 964):
  switch the predicate from `m.reply_to_id = $1` to
  `m.thread_root_id = $1`. The endpoint now returns every message in the
  thread, not just direct replies to the root — which matches Slack's
  flat-tree shape.
- **REST endpoint** (`apps/server/src/routes/messages.rs` line 515):
  alias to `GET /api/messages/:thread_root_id/thread`; keep `/replies` as
  a deprecated alias for one release.
- **Send path** (`apps/server/src/ws/message_service/mod.rs`
  `handle_send_message`): accept `thread_root_id: Option<Uuid>` on the
  inbound `SendMessage` frame, propagate through `store_and_confirm` and
  the `ServerMessage::NewMessage` fanout.
- **Fanout** (`apps/server/src/ws/message_service/fanout.rs`): no routing
  change — thread subscription is implicit (every channel member can read
  the thread). The frame just gains a `thread_root_id` field that tells
  the client where to render it.
- **WS frame** (`ServerMessage::NewMessage` in
  `apps/server/src/ws/protocol.rs` and the matching `NewMessageFields` in
  `fanout.rs` lines 30–80): add `thread_root_id: Option<Uuid>`. Old
  clients decode unknown fields as null → main channel, which is the
  back-compat behaviour we want.
- **Client model** (`apps/client/lib/src/models/chat_message.dart` lines
  52–62): add `final String? threadRootId`. Parse from
  `json['thread_root_id']`; thread through `copyWith` / `==` / `hashCode`.
- **Main-stream filter** (`chat_panel/chat_message_list.dart`): wrap
  `messages` with `.where((m) => m.threadRootId == null).toList()` before
  the `ListView.builder`. One line, but it's the line that makes the
  channel clean.
- **ThreadViewPanel** (`widgets/thread_view_panel.dart` line 147): change
  `.where((m) => m.replyToId == parent.id)` to
  `.where((m) => m.threadRootId == parent.id)`. Now sees the flat thread,
  not just direct replies.
- **MessageItem compose actions** (`widgets/message_item.dart`, ~1850
  LoC): split the existing "Reply" menu item into **Reply** (inline
  quote, lands in main channel — today's behaviour) and **Reply in
  thread** (sets `thread_root_id`, opens `ThreadViewPanel`).
- **`chatProvider.sendMessage`** (`providers/chat/chat_provider.dart`
  line 123+): accept a `threadRootId` parameter, propagate to the
  `SendMessage` WS frame, store on the optimistic local copy.
- **History fetch** (`providers/chat/chat_history.dart`): no logical
  change — the server already filters thread messages out of
  `get_messages`. Add a `loadThreadHistory(rootId)` helper later if
  needed; until then `ThreadViewPanel._loadReplies` works against the
  deprecated `/replies` alias.
- **Encryption** (`services/group_crypto_service.dart`): no envelope
  changes. Threads share the parent channel's group key — a threaded
  ciphertext is just another `GRP2:`-prefixed payload encrypted under
  the same key. Worth saying out loud so future maintainers don't reach
  for a per-thread key.

---

## 4. Hard parts (be honest)

- **Backfilling existing replies.** Two options: (a) walk every existing
  `reply_to_id` chain to its root and backfill `thread_root_id` — safe, but
  turns every pre-existing inline reply into a thread reply that vanishes
  from the main timeline, surprising users who never intended threads. (b)
  Leave existing replies in the main timeline; thread-mode is opt-in for
  new replies only. Recommendation: (b). The semantic shift is too large
  to apply retroactively.
- **WS frame back-compat.** Old clients ignore the new `thread_root_id`
  field and default to `null` → main channel, which is correct on the
  read side. On the write side, an old client replying to a thread root
  will not set `thread_root_id` and would dump the reply into the main
  channel. Mitigation: server-side inference — if `reply_to_id` is set
  and the parent has `thread_root_id IS NOT NULL` (or is itself a root
  with replies), fill in `thread_root_id` automatically.
- **Notifications.** Slack's rule: a threaded reply pings non-subscribers
  only on @mention. Echo today notifies every member uniformly.
  Implementing this needs a `thread_subscriptions` table and a tweak to
  `notify_offline_users` in `apps/server/src/push/`.
- **Unread state.** Echo's `read_receipts` is
  `(conversation_id, user_id, last_read_at)` — no thread dimension. Per-
  thread unread is its own milestone. Stopgap: the pane shows
  `replyCount` (already plumbed) without a proper unread badge.
- **Mobile.** The desktop side-pane becomes a full-screen route on phones.
  `showThreadBottomSheet` (`thread_view_panel.dart` line 445) is a
  starting point, but deep-linking, back-button behaviour, and an "All
  threads" entry are real product work.
- **Search / jump-to-message.** A global search hit on a threaded message
  must open the parent's thread pane, not the main channel (which no
  longer contains it). The existing `onJumpToReplyQuote` hook
  (`chat_message_list.dart` line 69) needs a sibling
  `onJumpToThreadMessage` that opens the pane and scrolls inside it.
- **Edits & deletes.** No new work — `edit_message` / `delete_message`
  (`apps/server/src/db/messages.rs` lines 572, 526) operate by `id` and
  don't care about thread state. The pane reactively reflects edits via
  shared `chatProvider` state.
- **Tests.** Need a Rust integration test that a threaded message is
  filtered from `get_messages` and included in `get_thread_replies`; a
  `ws_fanout` test confirming `thread_root_id` rides the frame; Flutter
  widget tests for the main-stream filter and "Reply in thread"
  compose action. `core/rust-core` is unaffected — `thread_root_id` is
  plaintext channel metadata, not ratchet state.

---

## 5. Effort sizing (be honest)

- **M1 — Schema + fanout filter + client filter: ~1 week.** Migration,
  `store_message` change, `get_messages` filter, `get_thread_replies`
  switch to `thread_root_id`, WS frame field, client model, main-stream
  filter, ThreadViewPanel filter switch. End state: existing
  ThreadViewPanel still works, but only *new* threaded replies vanish
  from the main timeline. Old `reply_to_id`-only messages stay inline.
  Tests: server integration + one Flutter widget test.
- **M2 — "Reply in thread" UI split: ~3–5 days.** MessageItem action
  menu split, ChatInputBar context-aware reply mode (a small banner
  above the input that says "Replying in thread"), the
  "Also send to channel" toggle. This is the user-facing milestone:
  ship M1+M2 and the feature is real.
- **M3 — Unread + notifications: ~1 week.** `thread_subscriptions`
  table, per-thread unread tracking, push routing for @mention-in-thread
  vs everyone-on-channel. Self-contained but touches the notification
  hot path.
- **M4 — Mobile + cross-screen plumbing: ~3–5 days.** Mobile thread
  route, search jump-to-thread-message, "All threads" view (optional
  for first ship; this is Slack's "Threads" sidebar entry).

Total: **~3–4 weeks of focused work** for full Slack-parity. M1+M2 alone
is ~1.5–2 weeks and gives the user what they asked for ("threads as
sub-channels with a single thread").

---

## 6. Recommendation

**Do M1 + M2 now, defer M3 and M4 to post-beta.**

The user's stated pain — "the main channel becomes noisy in active threads"
— is fully solved by M1 (server filter + client filter) plus M2 (UI to opt
into thread mode at compose time). That's ~1.5–2 weeks and ships clean:
existing inline replies stay where they are (no surprising backfill), new
replies get a "Reply in thread" choice, and threaded messages disappear
from the main channel the way Slack handles it.

Skipping M3/M4 means thread unread is approximated by `replyCount` and
every channel member is notified on every thread reply. Both are
acceptable for beta — they're Echo's current defaults — and both can be
added later without re-doing M1/M2.

The smaller alternative — M1 only, with a single "Reply" action that
always opens the thread pane — is tempting but removes the inline quoted
reply pattern users already rely on. Splitting the action in M2 keeps
both modes available, which is what Slack itself does.

Concretely: schedule M1 for the next sprint, M2 for the sprint after,
and file separate issues for M3 and M4 to revisit once beta usage data
shows how heavily threads are actually used.
