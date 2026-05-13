# Frontend Audit — 2026-05-09

Single-pass audit of the Flutter client focused on the recent @riverpod codegen
migration (chat_provider, websocket_provider) and the message_item split.
Skips items already tracked by #783 / #784.

### Finding 1: AnimationController listener leak in MessageItem swipe-back
- **File**: apps/client/lib/src/widgets/message_item.dart:199
- **Severity**: medium
- **Description**: `_startSpringBack` builds a fresh `Tween<>.animate()` and attaches an `addListener` callback to `_swipeAnimController` every time the user finishes a swipe. The listener is never removed, and because `_swipeAnimController` is reused across swipes (built once in `initState`), each swipe leaks one closure that captures `setState` and the previous `animation` reference. After 30+ swipes the controller fires N listeners on every tick — wasted setState calls and a real memory retention path. Long-lived chat panels with mobile users will accumulate this until dispose.
- **Code**:
```dart
animation.addListener(() {
  if (mounted) setState(() => _swipeDx = animation.value);
});
_swipeAnimController.forward(from: 0);
```
- **Fix**: Hoist the listener to a single instance variable attached once in `initState` that reads `_swipeAnimController.value` against a stored `_springStart`, or cache the listener and remove it in `onComplete`. Easiest: drive `_swipeDx` from a `ValueListenableBuilder` on the controller value with a `_springStart` field, and just call `_swipeAnimController.forward(from: 0)`. No re-attached listeners.
- **Effort**: small

### Finding 2: WebSocketChannel.connect can throw and orphan reconnect state
- **File**: apps/client/lib/src/providers/websocket_provider.dart:173
- **Severity**: high
- **Description**: `_channel = WebSocketChannel.connect(uri)` is not wrapped in try/catch. On web (CanvasKit / dart2js) `WebSocketChannel.connect` can throw synchronously for invalid URIs (e.g. malformed `serverUrlProvider` value, mixed-content `ws://` from an https origin). Because the call is preceded by `state = state.copyWith(isConnected: true, ...)` on line 174, an exception leaves `isConnected=true` while no channel exists. `_subscription` is never assigned, no `onDone`/`onError` will fire, and the heartbeat monitor will eventually call `disconnect()` 60s later — but until then any `_channel?.sink.add(...)` silently no-ops and messages appear to send into a void. The user sees "online" with messages stuck on `sending`.
- **Code**:
```dart
final uri = Uri.parse('$wsBase/ws?ticket=$ticket');
_channel = WebSocketChannel.connect(uri);
state = state.copyWith(isConnected: true, reconnectAttempts: 0);
```
- **Fix**: Wrap the connect + initial state mutation in try/catch; on failure mark `isConnected: false`, log via `DebugLogService`, and call `_scheduleReconnect()`. Only set `isConnected: true` after `_subscription = _channel!.stream.listen(...)` is established without throwing.
- **Effort**: small

### Finding 3: Reconnect can race manual connect() and produce two channels
- **File**: apps/client/lib/src/providers/websocket_provider.dart:272
- **Severity**: medium
- **Description**: When the reconnect timer fires it only checks `ref.read(authProvider).isLoggedIn` and then calls `_connectWithTicketOrFallback()`. It does NOT check whether `_channel != null` already (e.g. the user manually called `connect()` after toggling server URL, or the `serverUrlProvider` listener fired `connect()` on line 76). Two parallel `_connectWithTicketOrFallback()` calls overwrite `_channel` and `_subscription` mid-async, the orphaned channel keeps streaming into a now-detached `onDone` closure that mutates state, and `clearOnlineUsers()` can fire after a successful reconnect, blanking presence. Hard to reproduce locally but very likely on flaky mobile networks plus a server-URL change.
- **Code**:
```dart
_reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
  if (ref.read(authProvider).isLoggedIn) {
    _connectWithTicketOrFallback();
  }
});
```
- **Fix**: Guard with `if (_channel != null && state.isConnected) return;` before reconnecting. Also call `disconnect()` at the top of `_connectWithTicketOrFallback` (which it already does in `connect()`) so concurrent invocations serialize.
- **Effort**: small

### Finding 4: `_pendingDecryptQueue` survives logout + login, leaking other-user ciphertext
- **File**: apps/client/lib/src/providers/ws_message_handler.dart:142
- **Severity**: high
- **Description**: `_pendingDecryptQueue` is an instance field on the `WsMessageHandler` mixin. It is only drained by `drainPendingDecryptQueue` after crypto initialises; it is NEVER cleared on `disconnect()`, `session_replaced`, or `device_revoked` -> `logout()`. Because `WebSocketNotifier` is `@Riverpod(keepAlive: true)`, the same notifier instance survives logout/login as long as the app process lives. If user A is mid-login (crypto not yet initialised) and queues messages, then logs out before drain, user B's login will trigger `drainPendingDecryptQueue(myUserIdB)` in `crypto_provider.dart:165` and try to decrypt user A's ciphertext as user B — the messages will land in user B's chat as `[Could not decrypt - encryption keys may be out of sync]` and worse, the JSON envelope's `from_user_id` / `conversation_id` from user A's session leak into user B's `chatProvider` and `conversationsProvider.onNewMessage`.
- **Code**:
```dart
final List<Map<String, dynamic>> _pendingDecryptQueue = [];
```
- **Fix**: Clear `_pendingDecryptQueue` inside `disconnect()` and inside `_handleSessionReplaced` / `_handleDeviceRevoked`. Also clear it in `chatProvider.notifier.clear()`'s caller path at logout.
- **Effort**: small

### Finding 5: `_handleMessageSent` calls confirmSent and updateMessageStatus back-to-back, double rebuild
- **File**: apps/client/lib/src/providers/ws_handlers/message_handlers.dart:16
- **Severity**: low
- **Description**: `confirmSent` already sets `status: MessageStatus.sent` on the replaced pending message (chat_provider.dart:442). The handler then immediately calls `updateMessageStatus(conversationId, messageId, MessageStatus.sent)`. This re-iterates the entire conversation list with `.map`, allocates a new list, and rewrites `messagesByConversation` again — every connected listener (chat_panel, conversation_panel, conversations_provider preview consumers) rebuilds twice per outgoing message. On a lively conversation that's 2x the rebuild work for nothing.
- **Code**:
```dart
ref.read(chatProvider.notifier).confirmSent(messageId, conversationId, timestamp, ...);
ref.read(chatProvider.notifier).updateMessageStatus(conversationId, messageId, MessageStatus.sent);
```
- **Fix**: Drop the redundant `updateMessageStatus` call. `confirmSent` already transitions status to `sent` atomically with the ID swap.
- **Effort**: small

### Finding 6: `addOptimistic` increments reply count but `_transitionToFailed` never decrements
- **File**: apps/client/lib/src/providers/chat_provider.dart:303
- **Severity**: medium
- **Description**: When the user sends a reply optimistically, `_incrementReplyCount` bumps the parent's `replyCount` (chat_provider.dart:303-305). If the send times out and `_transitionToFailed` runs, the failed message stays in the conversation but the replyCount stays inflated. Repeated retries-then-timeouts compound: a failed reply gets re-sent via `_retryMessage` which pushes another optimistic copy, incrementing replyCount again. The "X replies" badge under the parent grows monotonically and never reconciles with server truth (server only counts successful replies).
- **Code**:
```dart
if (replyToId != null) {
  newState = _incrementReplyCount(newState, conversationId, replyToId);
}
```
- **Fix**: In `_transitionToFailed` and `deleteMessage` (when removing a `pending_*` reply), decrement the parent's reply count by 1 if `replyToId` is set. Alternative: only increment on `confirmSent` for outgoing replies, mirroring the server-truth semantics.
- **Effort**: small

### Finding 7: ReplyQuote uses hardcoded `Colors.white` that breaks under light theme
- **File**: apps/client/lib/src/widgets/message/reply_quote.dart:66
- **Severity**: medium
- **Description**: The reply-quote left-border, background tint, and username/preview text colors hardcode `Colors.white` for `isMine` regardless of the active theme. This assumes `context.sentBubble` is always dark. The codebase supports user-configurable themes via ThemeExtension (`feedback theme: upgrade theme to ThemeExtension for scalable custom themes`); a light-or-pastel sent-bubble theme leaves the reply quote unreadable (white text on white-ish background, invisible left border). CLAUDE.md explicitly requires theme-aware colors.
- **Code**:
```dart
color: (isMine ? Colors.white : context.accent).withValues(alpha: 0.12),
...
color: isMine ? Colors.white.withValues(alpha: 0.5) : context.accent,
```
- **Fix**: Replace the `isMine ? Colors.white : ...` ternaries with `Theme.of(context).colorScheme.onPrimary` (or expose a `context.onSentBubble` helper in `EchoTheme` that resolves to the contrast color of `sentBubble`). The same pattern repeats at lines 73, 90, 106 in this file.
- **Effort**: small

### Finding 8: ReactionBar emits `Colors.white` text on sent bubbles regardless of theme
- **File**: apps/client/lib/src/widgets/message/reaction_bar.dart:202
- **Severity**: medium
- **Description**: Same theme bug as Finding 7 in a separate widget extracted by the recent split. `final textColor = widget.isMine ? Colors.white : context.textPrimary;` will produce illegible reaction counts on light-themed sent bubbles. The reaction count fills `context.sentBubble` background with `Colors.white` foreground, but no theme contract guarantees `sentBubble` is dark.
- **Code**:
```dart
final textColor = widget.isMine ? Colors.white : context.textPrimary;
```
- **Fix**: Use `Theme.of(context).colorScheme.onPrimary` or a new `context.onSentBubble` helper. Remove the literal `Colors.white`.
- **Effort**: small

### Finding 9: `_lastTypingSent` map grows unbounded
- **File**: apps/client/lib/src/providers/websocket_provider.dart:55
- **Severity**: low
- **Description**: `_lastTypingSent` accumulates one entry per `conversationId:channelId` the user has typed in for the lifetime of the keepAlive notifier (i.e. the entire app session). For users who browse many channels in a long-lived session, this map grows without bound. Not a critical leak, but easy to fix and matches the existing `_typingCleanupTimer` pattern that already runs every 2 s.
- **Code**:
```dart
final Map<String, DateTime> _lastTypingSent = {};
```
- **Fix**: In `_cleanupTyping()` (called every 2 s), also remove `_lastTypingSent` entries older than 30 s. They serve no purpose past the throttle window.
- **Effort**: small

### Finding 10: `connect()` clobbers `wasReplaced` state without checking
- **File**: apps/client/lib/src/providers/websocket_provider.dart:145
- **Severity**: medium
- **Description**: `connect()` unconditionally clears `wasReplaced` to `false` before scheduling reconnect attempts. The intent is "manual page refresh re-enables reconnect after a session-replaced event" — but the side effect is that the `serverUrlProvider` listener at line 68 calls `disconnect() + connect()` whenever the user changes server URL, which silently re-enables an unwanted reconnect path on a session that the server already considers replaced. The new server may then surface a duplicate `session_replaced` immediately, racing the UI banner.
- **Code**:
```dart
disconnect();
_reconnectAttempts = 0;
// Clear wasReplaced so a manual reconnect (e.g. page refresh) works.
state = state.copyWith(wasReplaced: false);
```
- **Fix**: Move the `wasReplaced=false` reset to a dedicated `reconnectAfterReplacement()` method that the UI calls explicitly when the user dismisses the "session replaced" banner. Don't clear it on every `connect()`.
- **Effort**: small

### Finding 11: GestureDetector wrapped around bubble has button-semantics, doubling touch target
- **File**: apps/client/lib/src/widgets/message_item.dart:1742
- **Severity**: low
- **Description**: `Semantics(label: ..., button: true, child: GestureDetector(onLongPressStart: ...))` declares the bubble as a button to assistive tech, but the bubble doesn't have an `onTap` — only `onLongPressStart`. Screen readers announce "double tap to activate" suggesting a tap is the action, then the tap does nothing. Inconsistent UX; the actual action is long-press. Also, `MergeSemantics` lower in the tree (line 1281) merges the inner content into the bubble's semantics, but the parent `Semantics(button: true)` ignores `onTapHint`/`onLongPressHint`.
- **Code**:
```dart
child: Semantics(
  label: _composeMessageSemanticsLabel(msg, isMine),
  button: true,
  child: GestureDetector(
    onLongPressStart: (details) => _handleLongPress(...),
```
- **Fix**: Replace `button: true` with explicit `onTapHint`/`onLongPressHint` so the announcement reads "Long press for actions" without claiming tap-to-activate. The composite label string already says "Long press for actions" but VoiceOver/TalkBack use the role hint, not the label tail. Alternatively wire `onTap` to open the action sheet too, matching the announcement.
- **Effort**: small

### Finding 12: SenderNameLabel timestamp re-formats every rebuild (no `key` continuity)
- **File**: apps/client/lib/src/widgets/message/sender_name_label.dart:65
- **Severity**: low
- **Description**: After the message_item split (commit a36a01d), `SenderNameLabel` is a fresh `StatelessWidget` instantiated inline inside `_bubbleChildren` (message_item.dart:1209). It has no `key` — Flutter uses index-based reconciliation by default, which is fine, but `formatMessageTimestamp(message.timestamp)` (line 66) is called on every parent rebuild even though `message.timestamp` rarely changes. Multiplied across 50+ visible messages and frequent parent rebuilds (typing indicators, presence updates, hover state), this is wasted work in `intl` formatter on the hot path. Same pattern in `_buildHoverTimestamp` and `_buildTimestampRow` in message_item itself.
- **Code**:
```dart
Text(
  formatMessageTimestamp(message.timestamp),
  style: GoogleFonts.inter(fontSize: timestampFontSize, color: context.textMuted),
),
```
- **Fix**: Memoise the formatted string at `ChatMessage` construction (e.g. add a `formattedTimestamp` getter that lazily caches), or cache the result inside `SenderNameLabel` via `RepaintBoundary` is not enough — better: precompute in the parent and pass as a `String` prop. For low-effort wins, add `const` widgets where possible and consider `ValueKey(message.id)` so reconciliation skips rebuilds when message identity is stable. Same pass should review `message_item.dart:1364` and `1446`.
- **Effort**: medium

---

Files referenced (absolute):
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/widgets/message_item.dart
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/widgets/message/reply_quote.dart
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/widgets/message/reaction_bar.dart
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/widgets/message/sender_name_label.dart
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/providers/websocket_provider.dart
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/providers/chat_provider.dart
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/providers/ws_message_handler.dart
- /home/npc/Documents/projects/decentralized-chat-app/apps/client/lib/src/providers/ws_handlers/message_handlers.dart
