# Quality + Architecture + Performance audit (2026-05-09)

Single-pass audit of Echo Messenger. Run after #783 backlog (2026-04-30); items already covered there are not duplicated.

### Finding 1: Unused FFI-era deps still bloat `core/rust-core`
- **Lens**: quality
- **File**: core/rust-core/Cargo.toml:21
- **Severity**: medium
- **Description**: CLAUDE.md confirms the FFI bridge to Dart never landed and the Dart client re-implements Signal in pure Dart. `tokio-tungstenite`, `reqwest`, and `rusqlite` (with the heavyweight `bundled-sqlcipher` feature) are still declared as `core/rust-core` dependencies but no `use` of them exists in `core/rust-core/src/`. `rusqlite + sqlcipher` alone bumps build time and image size on every CI run, and pulls a C toolchain dep that nothing uses. `tokio` with `features = ["full"]` is also overkill for a pure-crypto crate that has no async surface.
- **Code**:
```toml
tokio-tungstenite = { version = "0.28", features = ["native-tls"] }
reqwest = { version = "0.13", features = ["json"] }
rusqlite = { version = "0.32", features = ["bundled-sqlcipher"] }
```
- **Fix**: Delete the three deps from `core/rust-core/Cargo.toml`. Trim `tokio` features to what `signal/` actually uses (likely none; the crate is sync). Run `cargo build -p echo-core` to confirm; expect a sizable lock-file diff and faster CI.
- **Effort**: small

### Finding 2: `MessageDto` has triple-named duplicate fields on the wire
- **Lens**: quality
- **File**: apps/server/src/routes/messages.rs:104
- **Severity**: medium
- **Description**: `MessageDto` ships `id` AND `message_id` (same value), `sender_id` AND `from_user_id` (same), `sender_username` AND `from_username` (same). Every history response pays serialization cost for redundant fields and the client now has two equally valid spellings for each piece of data. New code that lands on either spelling will silently diverge from existing code that uses the other. This is a textbook naming-inconsistency / dead-data hazard inside a hot endpoint (history reload).
- **Code**:
```rust
pub struct MessageDto {
    pub id: Uuid,
    pub message_id: Uuid,
    pub sender_id: Uuid,
    pub from_user_id: Uuid,
    pub sender_username: String,
    pub from_username: String,
```
- **Fix**: Pick one canonical name per concept (the "from_*" spelling matches the WebSocket `NewMessage` event so REST should match it). Mark the legacy fields `#[deprecated]` for one release, then remove. Drop the redundant `String` clones in `From<MessageWithSender>` (line 138).
- **Effort**: medium

### Finding 3: `mentions_broadcast` and `is_standalone_keyword` are byte-for-byte duplicates
- **Lens**: quality
- **File**: apps/server/src/db/mentions.rs:24
- **Severity**: low
- **Description**: `is_standalone_keyword` in `db/mentions.rs` (lines 24-53) is functionally identical to `mentions_broadcast` in `ws/message_service.rs` (lines 1039-1067) — same lowercase target build, same start/end + non-word boundary check, same loop structure. They were almost certainly copy-pasted in the same #451 follow-up. A future bugfix to one will silently leave the other broken.
- **Code**:
```rust
fn is_standalone_keyword(content: &str, keyword: &str) -> bool {
    if !content.contains('@') { return false; }
    let target = format!("@{}", keyword.to_lowercase());
    let lower = content.to_lowercase();
```
- **Fix**: Promote one copy to a public helper in a small `mentions_util` module (e.g. `db::mentions::contains_standalone_at_keyword`) and have the WS path call into it. Delete the duplicate.
- **Effort**: small

### Finding 4: Six identical `send_error(... "Encrypted conversation requires ciphertext payload")` calls
- **Lens**: quality
- **File**: apps/server/src/ws/message_service.rs:119
- **Severity**: low
- **Description**: `validate_encrypted_payload` calls `send_error` with the same string at lines 119, 132, 145, 160, 176, 194 — six branches each emit a unique `tracing::warn!` (good) but then spew the same client-facing string verbatim (bad). The branches differ only in the warn tag, so the call sites are crying out for a small helper that takes a `(reason: &'static str)` discriminant and emits the right warn while sending one canonical error frame.
- **Code**:
```rust
send_error(state, sender_id, "Encrypted conversation requires ciphertext payload");
return false;
```
- **Fix**: Extract `fn reject_encrypted(state, sender_id, conv_id, reason: &'static str) -> bool` that does `warn!` with the reason tag and the single `send_error`. Call sites become two lines.
- **Effort**: small

### Finding 5: `MessageItem` setState on hover rebuilds entire bubble per mouse move
- **Lens**: performance
- **File**: apps/client/lib/src/widgets/message_item.dart:1740
- **Severity**: medium
- **Description**: Every `MessageItem` wraps the bubble in a `MouseRegion` whose `onEnter` and `onExit` call `setState(() => _isHovered = ...)`. That triggers a full rebuild of the 160-line `build()` method (which constructs `ReactionBar`, `_buildBubble`, `_buildBubbleWithReactions`, sender name, reply quote, swipe gesture wiring, `AnimatedOpacity`, `Semantics`, `GestureDetector`) every time the cursor crosses any message bubble in the list. On a 100-message conversation that's a rebuild storm during normal pointer travel.
- **Code**:
```dart
child: MouseRegion(
  onEnter: (_) => setState(() => _isHovered = true),
  onExit: (_) => setState(() => _isHovered = false),
```
- **Fix**: Replace `_isHovered` bool with a `ValueNotifier<bool>` and wrap only the hover-action overlay (the only widget that actually depends on `_isHovered`) in a `ValueListenableBuilder`. The body of `build()` reads the field once for the overlay branch only, so a notifier scoped to that subtree avoids rebuilding bubble/text/reactions.
- **Effort**: small

### Finding 6: `ChatPanel.build` watches the entire `chatProvider` state
- **Lens**: performance
- **File**: apps/client/lib/src/widgets/chat_panel.dart:1746
- **Severity**: high
- **Description**: `final chatState = ref.watch(chatProvider);` grabs the whole `ChatState` (messages-by-conversation map, indices, loading-flags map, hasMore map, replyToMessage). Adding a single message to *any* conversation produces a new `ChatState` instance and rebuilds the entire `ChatPanel` (a 2000-line widget that mounts the message list, header, channel bar, drop zones, etc.). The neighbouring lines already use `.select()` correctly for `authProvider`/`websocketProvider`; this one regressed.
- **Code**:
```dart
final chatState = ref.watch(chatProvider);
final messages = _resolveMessages(conv, chatState, selectedChannelId, includeUnchanneled);
```
- **Fix**: Replace with a tuple selector that only reads what `_resolveMessages` and `isLoadingHistory` actually consume for *this* conversation:
```dart
final (messages, isLoadingHistory) = ref.watch(chatProvider.select((s) => (
  s.messagesForConversationChannel(conv.id, channelId: selectedChannelId, includeUnchanneled: includeUnchanneled),
  s.isLoadingHistory(conv.id, channelId: selectedChannelId),
)));
```
This makes a typing event in conversation B no longer rebuild conversation A's panel.
- **Effort**: small

### Finding 7: `send_presence_snapshot` is N+1 on `get_presence_status`
- **Lens**: performance
- **File**: apps/server/src/ws/typing_service.rs:280
- **Severity**: medium
- **Description**: For every reconnect the snapshot loop iterates each online contact and issues a separate `db::users::get_presence_status` query (one round-trip per online contact). On reconnect for a user with N online contacts that's N sequential queries on a hot path; the queries also fall in the WS handler's startup window, delaying the first server frame the client sees.
- **Code**:
```rust
for cid in &online_contacts {
    let stored = db::users::get_presence_status(&state.pool, *cid)
        .await
        .unwrap_or(None)
        .unwrap_or_else(|| "online".to_string());
```
- **Fix**: Add `db::users::get_presence_statuses_for(&pool, &user_ids: &[Uuid]) -> HashMap<Uuid, String>` that does a single `WHERE id = ANY($1)`, then build entries from the map. Same pattern is repeated in `broadcast_presence` for a single user (fine) but the snapshot path is the bulk caller.
- **Effort**: small

### Finding 8: `search_messages` and `get_thread_replies` still use LATERAL reply_count (O(N×M))
- **Lens**: performance
- **File**: apps/server/src/db/messages.rs:554
- **Severity**: medium
- **Description**: `get_messages` (line 241) was migrated to a single GROUP-BY subquery for `reply_count` (O(N+M), explicitly called out in the comment at line 224). `search_messages` (line 554) and `get_thread_replies` (line 916) still use `LEFT JOIN LATERAL (SELECT COUNT(*) ...)` correlated subqueries, which Postgres re-executes per row. These three queries are the only callers of `MessageWithSender`; the inconsistency is recent and intentional looking by accident — the refactor stopped halfway.
- **Code**:
```sql
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS cnt FROM messages r
    WHERE r.reply_to_id = m.id AND r.deleted_at IS NULL
) rc ON true
```
- **Fix**: Replace both LATERAL subqueries with the same `LEFT JOIN (SELECT reply_to_id, COUNT(*) FROM messages WHERE reply_to_id IS NOT NULL AND deleted_at IS NULL GROUP BY reply_to_id) rc ON rc.reply_to_id = m.id` pattern used in `get_messages`. The `idx_messages_reply_to_id` partial index (migration 20260423000000) already supports it.
- **Effort**: small

### Finding 9: WS broadcast logic duplicated across routes (channels, reactions, users, messages)
- **Lens**: architecture
- **File**: apps/server/src/routes/channels.rs:142
- **Severity**: medium
- **Description**: Each of `routes/channels.rs`, `routes/reactions.rs`, `routes/users.rs`, `routes/messages.rs`, `routes/groups.rs` reaches into `state.hub` directly and re-implements the same "look up members, serialize JSON, fan out, log on error" pattern. `channels.rs` calls `db::groups::get_conversation_member_ids`, `reactions.rs` does the same with custom exclude logic, `users.rs` walks the contact graph. The hub abstraction is leaking up to the route layer instead of being mediated by `ws/` services. New routes that need to broadcast will copy whichever neighbour was nearest, so the patterns will keep drifting.
- **Code**:
```rust
async fn broadcast_to_group(state: &AppState, group_id: Uuid, event: &serde_json::Value) {
    let member_ids = match db::groups::get_conversation_member_ids(&state.pool, group_id).await { ... };
    if let Ok(json) = serde_json::to_string(event) { state.hub.broadcast_json(...); }
}
```
- **Fix**: Pull the broadcast helpers up into `ws/broadcast.rs` (or extend `ws::message_service`) with `broadcast_to_conversation`, `broadcast_to_user_contacts`, `broadcast_to_member_set` taking `Serialize` events. Routes then call `crate::ws::broadcast::to_conversation(&state, conv_id, &event, exclude)` instead of touching `state.hub` directly. Keeps the `Hub` type out of `routes/`.
- **Effort**: medium

### Finding 10: `Hub::send_to_user` allocates a `Vec<(i32, WsTx)>` on every send
- **Lens**: performance
- **File**: apps/server/src/ws/hub.rs:109
- **Severity**: low
- **Description**: Every `send_to_user` call snapshots the user's device map into a heap-allocated `Vec` so the inner DashMap ref can be dropped before `try_send_tracked` (which may unregister and re-enter the map on slow-consumer eviction). On a high-fanout group message the comment in `fanout_message` says clones are O(1), but per-recipient hub dispatch still pays one `Vec` allocation + per-device `WsTx` clone (Arc bump). For a 100-member group at peak load that's 100 vecs per message, all immediately discarded.
- **Code**:
```rust
let device_ids: Vec<(i32, WsTx)> = {
    let Some(devices) = self.inner.connections.get(user_id) else { return false; };
    devices.iter().map(|e| (*e.key(), e.value().clone())).collect()
};
```
- **Fix**: Most users have one device; use a `SmallVec<[(i32, WsTx); 2]>` (or hand-roll a stack-first 1-or-2 case) so the common path never hits the allocator. Alternatively, hold the read ref across `try_send` and only re-enter the map for the slow-consumer eviction (which is rare). Bench in `benches/hub.rs` first.
- **Effort**: small

### Finding 11: AppState exposes raw `pool`, `hub`, `ticket_store` to every route
- **Lens**: architecture
- **File**: apps/server/src/routes/mod.rs:44
- **Severity**: medium
- **Description**: `AppState` is the bag-of-dependencies pattern: `pool`, `jwt_secret`, `hub`, `ticket_store`, `media_tickets`. Every route handler takes `State<Arc<AppState>>` and reaches into whichever field it needs, so there's no compile-time signal of which routes touch which subsystem. This means a route can accidentally reach the WS hub or vice-versa (Finding 9 is the symptom). #783 already flagged this for `FromRef`, but the harder problem is that `jwt_secret` (a String) is co-mingled with `Hub` (a clone-cheap Arc handle) and the ticket stores (DashMaps), so no narrower extractor is meaningful without restructure.
- **Code**:
```rust
pub struct AppState {
    pub pool: PgPool,
    pub jwt_secret: String,
    pub hub: Hub,
    pub ticket_store: TicketStore,
    pub media_tickets: MediaTicketStore,
}
```
- **Fix**: Wrap the auth-only deps in `AuthState { jwt_secret, ticket_store }`, the WS deps in `WsState { hub, media_tickets }`, keep `pool` shared, and use `axum::extract::FromRef` to project subsets. Pure REST routes that only touch `pool + jwt_secret` no longer carry the hub. Pairs naturally with Finding 9.
- **Effort**: large

### Finding 12: `chat_panel.dart` is 2030 lines doing routing, scroll, drag-drop, history, search, and forwarding
- **Lens**: architecture
- **File**: apps/client/lib/src/widgets/chat_panel.dart:1
- **Severity**: medium
- **Description**: Despite the recent extraction of `chat_panel/` sub-widgets (chat_message_list, drop_overlay, floating_date_pill, full_reaction_picker, new_messages_pill, no_conversation_placeholder), the parent file still owns: scroll-position management, history pagination, mark-as-read, message forwarding, image gallery launching, drop-target file handling, paste handling, channel selection, member-avatar map building, typing-text composition, unread-boundary capture, and ~50 `ref.read` sites. 47 imports in one widget is a smell. The build method (Finding 6) is the symptom; the file's responsibility count is the cause.
- **Code**:
```dart
// 47 imports, 2030 lines, single ConsumerStatefulWidget
class _ChatPanelState extends ConsumerState<ChatPanel>
    with TickerProviderStateMixin, WidgetsBindingObserver {
```
- **Fix**: Extract a `ChatPanelController` (plain Dart class, not a widget) that owns scroll + history + read-receipt state and exposes a small surface to the widget. Move forward-message and image-preview launching into their own dialog services. Aim for the widget to be < 800 lines doing only layout + Riverpod glue.
- **Effort**: large

### Finding 13: `reactions::broadcast_to_conversation` re-fetches members and skips the cached path
- **Lens**: performance
- **File**: apps/server/src/routes/reactions.rs:184
- **Severity**: low
- **Description**: Reaction add/remove broadcasts via a private helper that calls `db::groups::get_conversation_member_ids` directly, even though `ws::typing_service::get_member_ids_cached` exists and is what the message-fanout path uses. Each reaction click on an active group conversation triggers a fresh DB roundtrip for the member list, plus N `hub.send_to` calls in series. `mark_read` doesn't broadcast at all but the same shape recurs in groups.rs/users.rs.
- **Code**:
```rust
let member_ids = match db::groups::get_conversation_member_ids(&state.pool, conversation_id).await {
    Ok(ids) => ids,
    Err(e) => { tracing::error!(...); return; }
};
```
- **Fix**: Either expose `get_member_ids_cached` from `ws::typing_service` as `pub` (or move it into `ws::membership_cache`) and call it here, or use `Hub::broadcast_json` once the unified broadcast helper from Finding 9 lands. Same change for the channel and user-presence routes.
- **Effort**: small

### Finding 14: `chat_input_bar.build` watches whole `authProvider` to read one field
- **Lens**: performance
- **File**: apps/client/lib/src/widgets/chat_input_bar.dart:1829
- **Severity**: low
- **Description**: `final myUserId = ref.watch(authProvider).userId ?? '';` rebuilds the entire 1800-line `_ChatInputBarState.build` every time *any* field of `AuthState` changes (token refresh every 15 min, presence status flip, avatar update). Other watch sites in the same file already use `.select()` correctly. The pattern was missed in the codegen migration sweep.
- **Code**:
```dart
final myUserId = ref.watch(authProvider).userId ?? '';
final voiceSettings = ref.watch(voiceSettingsProvider);
```
- **Fix**: `final myUserId = ref.watch(authProvider.select((s) => s.userId)) ?? '';`. Same audit pass should sweep `chat_panel.dart:479,498,569,580,...` (those are `ref.read` so safe, but mark them so they don't drift to `.watch`).
- **Effort**: small

### Finding 15: `recipient_device_contents` keyed by stringified UUID/i32 round-trips through HashMap parse-on-every-fanout
- **Lens**: performance
- **File**: apps/server/src/ws/message_service.rs:773
- **Severity**: low
- **Description**: The wire type `RecipientDeviceContents = HashMap<String, HashMap<String, String>>` keeps strings even after the message is past the parse boundary. `build_per_device_json` (line 773), `store_and_confirm` (line 451), `fanout_message` (line 916) each independently call `Uuid::parse_str` and `did_str.parse::<i32>()` for the same data — three parse passes per recipient device per message. On a 50-member group with 2 devices each that's 300 redundant UUID parses per send.
- **Code**:
```rust
let recipient_id = Uuid::parse_str(uid_str).ok()?;
let did = did_str.parse::<i32>().ok()?;
```
- **Fix**: Convert at the WS-receive boundary (in `handler.rs` where `ClientMessage::SendMessage` is deserialized) to a `HashMap<Uuid, HashMap<i32, String>>`, then pass the typed map down. Drop the three parse helpers. Net: ~3× fewer string allocations and a tighter type signature.
- **Effort**: medium
