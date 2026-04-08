# Agent Memory: QA Audit 2026-04-08

Systematic root-cause analysis and verified fixes for 7 bugs found during
the Apr 6-7 testing sessions. All fixes verified at runtime with real
database, WebSocket connections, and Playwright UI testing.

---

## Bug 1: WebSocket Connection Drops Every ~4 Minutes

- **Problem**: WebSocket connections dropped constantly, causing reconnect loops.
- **Root Cause**: Server sent WebSocket **protocol Ping frames** (`WsMessage::Ping`)
  every 30s. Browser WebSocket APIs handle Ping/Pong at the protocol layer and
  do NOT surface them to JavaScript's `onMessage` event. The client's heartbeat
  monitor only checked `_lastMessageTime` (updated in `_onMessage`), so after
  60s of no application-level data it falsely declared the connection dead.
- **Why Previous Attempts Failed**: The server already had a 30s ping interval,
  which should keep proxy connections alive. But nobody realized browser JS
  can't see protocol-level Ping frames -- the fix addressed the wrong layer.
- **Final Fix**: Server now sends BOTH a protocol Ping (for proxy keepalive)
  AND an application-level `{"type":"heartbeat"}` text frame. Client adds a
  no-op `case 'heartbeat'` handler.
- **Generalizable Insight**: Browser WebSocket APIs are a strict subset of the
  WebSocket protocol. Protocol-level frames (Ping/Pong) are invisible to JS.
  Any browser-facing keepalive must use application-level data frames.
- **Prevention Strategy**: Always test WebSocket behavior in the actual browser,
  not just via native clients like `websocat`.
- **Verification**: Python websocket-client test: 3 heartbeats received at
  exactly 30s/60s/90s over 100s. Two-user messaging: both stayed connected
  40s with 1 heartbeat each. Playwright UI: green dot maintained after 35s idle.

---

## Bug 2: Screen Share UI State Desync

- **Problem**: Screen share button never toggled to "Stop sharing"; local preview
  never appeared.
- **Root Cause**: `voice_dock.dart` and `voice_lounge_screen.dart` started screen
  share via `lkNotifier.setScreenShareEnabled(true)` (LiveKit SDK). But the UI
  reads `screenShareProvider.isScreenSharing`, which is only set by
  `screenShareProvider.startScreenShare()` -- never called. Two separate
  providers for the same feature, with no bridge between them.
- **Why Previous Attempts Failed**: No previous fix attempted. The screen share
  was added with LiveKit but the local `ScreenShareProvider` was from the older
  P2P WebRTC path and was never updated.
- **Final Fix**: Added `setLiveKitScreenShareActive(bool)` to
  `ScreenShareNotifier` -- toggles state without calling `getDisplayMedia`.
  Updated both `voice_dock.dart` and `voice_lounge_screen.dart` to call it
  after successful LiveKit enable/disable.
- **Generalizable Insight**: When migrating from one media backend to another
  (P2P WebRTC -> LiveKit SFU), audit all UI state bindings. If the UI reads
  from Provider A but the action writes to Provider B, the state will never sync.
- **Prevention Strategy**: Single source of truth for feature state. Don't have
  two providers for the same capability.
- **Verification**: Code inspection (LiveKit not available locally). Static
  analysis clean. All 224 Flutter tests pass.

---

## Bug 3: Pin Message TOCTOU Race Condition

- **Problem**: Pinning a message in the wrong conversation would briefly succeed
  before being rolled back.
- **Root Cause**: `routes/messages.rs` pinned the message first (DB write), THEN
  checked if it belonged to the correct conversation. If mismatch, it unpinned
  and returned an error. Between pin and unpin, other users could see the
  message as pinned in the wrong conversation.
- **Why Previous Attempts Failed**: No previous fix. The pin-then-verify pattern
  was the original design.
- **Final Fix**: Added `conversation_id` parameter to `db::messages::pin_message`
  SQL: `WHERE id = $1 AND conversation_id = $3 AND deleted_at IS NULL`. Now
  atomic -- either the message belongs to the conversation and gets pinned, or
  nothing happens.
- **Generalizable Insight**: Never mutate-then-validate. Put the validation in
  the WHERE clause so the operation is atomic. This is the classic TOCTOU pattern.
- **Prevention Strategy**: All DB mutations should include ownership/membership
  checks in the WHERE clause, not as a separate query.
- **Verification**: Pinned message in correct conversation (200 OK). Attempted
  pin in wrong conversation (rejected by membership check). Verified original
  pin survived after wrong-conversation attempt.

---

## Bug 4: Notifications Not Firing

- **Problem**: Notifications didn't work on any platform.
- **Root Cause**: Three compounding issues:
  1. `main.dart:38` -- `requestPermission()` not awaited. On web, the
     `_permissionGranted` flag could be false when first messages arrived.
  2. `notification_service_stub.dart` -- Native init failure silently caught;
     `_initialized` stays false and all notifications silently dropped forever.
  3. Native service had no app-focus check, so when it DID work, it fired
     notifications even when the app was focused (unlike web which checks
     `document.hidden`).
- **Why Previous Attempts Failed**: The web implementation was correct (checks
  `document.hidden`), but the native implementation was a simpler port that
  didn't have the same guards.
- **Final Fix**: Awaited `requestPermission()`. Added `DebugLogService` logging
  on native init failure. Added `setAppFocused(bool)` to notification service
  interface. Wired it to `didChangeAppLifecycleState` in `home_screen.dart`.
- **Generalizable Insight**: Platform-specific implementations must have feature
  parity on behavioral guards (focus checks, permission state), not just API
  surface.
- **Prevention Strategy**: When implementing platform-specific services, create
  a shared behavioral contract (focus-aware, permission-aware) and verify each
  implementation satisfies it.
- **Verification**: Code inspection + Flutter analysis clean. Native focus
  tracking wired to lifecycle observer. Await prevents race condition on
  permission flag.

---

## Bug 5: Voice Names Show as UUIDs + Audio Level Mismatch

- **Problem**: Voice call participants showed as UUIDs. Speaking indicators
  never activated for remote peers.
- **Root Cause**: Two sub-bugs:
  1. Server (`routes/voice.rs:60`) forced LiveKit identity to
     `auth.user_id.to_string()` (UUID) and rejected any other value.
  2. `_pollAudioLevels` keyed levels by `p.name` (username), but
     `voice_lounge_screen.dart` looked them up by `p.identity` (UUID).
     Keys never matched -> `audioLevel` always 0.0.
- **Why Previous Attempts Failed**: The client workaround (`setName` after
  connect) was fragile -- it creates a race where remote participants see
  the UUID briefly. Nobody noticed the audio level key mismatch because
  it's a visual-only bug (speaking ring doesn't glow).
- **Final Fix**: Server now queries the username from DB and uses it as the
  LiveKit identity. Backward compatibility preserved -- UUID identity still
  accepted. Client audio levels now keyed by `p.identity` consistently.
  Screen share label uses `participant.name` with fallback.
- **Generalizable Insight**: When two systems (provider + UI) independently
  build keys for the same lookup table, they MUST agree on the key format.
  Use a single canonical key (identity) not a display-dependent one (name).
- **Prevention Strategy**: Key maps by stable identifiers, never by display
  names that may be empty or change.
- **Verification**: Voice token endpoint passes identity validation with
  username (reaches LiveKit config check). UUID identity still accepted
  (backward compat). Impersonation still blocked.

---

## Bug 6: Deafen State Corruption from Channel Bar

- **Problem**: After toggling deafen from the channel bar, un-deafening
  didn't restore the microphone.
- **Root Cause**: `channel_bar.dart:469` called `setCaptureEnabled(false)`
  BEFORE `setDeafened(true)`. Inside `setDeafened`, it saves
  `_wasMutedBeforeDeafen = !state.isCaptureEnabled`. Since capture was
  already disabled, `_wasMutedBeforeDeafen` was incorrectly `true`.
  On un-deafen, mic was not restored.
- **Why Previous Attempts Failed**: No previous fix. The voice_dock and
  voice_lounge implementations were correct -- only channel_bar had the
  extra `setCaptureEnabled` call.
- **Final Fix**: Removed the redundant `setCaptureEnabled` call before
  `setDeafened`. Let `setDeafened` manage mic state internally.
- **Generalizable Insight**: When a method manages internal state transitions
  (deafen saves pre-deafen mic state), callers must not pre-mutate the state
  that the method reads. This is a violation of encapsulation.
- **Prevention Strategy**: If a method reads-then-writes state, callers should
  not write that same state before calling the method.
- **Verification**: Code inspection. The voice_dock and voice_lounge
  implementations (which work correctly) don't have this call -- confirming
  the fix aligns with the working pattern.

---

## Bug 7: Message Delivery Tracking Waste

- **Problem**: No user impact, but wasteful allocation.
- **Root Cause**: `handler.rs` built a `delivered_ids` vector that pushed
  the same `stored_id` N times (once per online recipient), then only used
  it for an `is_empty()` check.
- **Final Fix**: Replaced with a boolean `any_delivered` flag.
- **Generalizable Insight**: When accumulating only to check non-emptiness,
  use a boolean.
- **Verification**: All 62 Rust tests pass. Message delivery confirmed in
  two-user WebSocket test.

---

## Common Failure Patterns Discovered

1. **Protocol vs Application Layer Confusion**: WebSocket protocol Pings
   are invisible to browser JavaScript. Any feature relying on frame-level
   semantics must verify behavior in the actual runtime environment.

2. **Dual-Provider State Desync**: When two providers manage overlapping
   state (ScreenShareProvider + LiveKitVoiceProvider), the UI will bind
   to one while actions write to the other. Always bridge or unify.

3. **Mutate-Then-Validate (TOCTOU)**: Database operations that write first
   and check after are vulnerable to race conditions. Push validation into
   the WHERE clause for atomicity.

4. **Platform Parity Gaps**: Platform-specific implementations (web vs
   native notification service) may implement the API but miss behavioral
   guards (focus checks, permission races).

5. **Key Format Mismatch**: When two components independently build lookup
   keys for the same map, they must agree on format. Use stable identifiers,
   never display-dependent values.

6. **Encapsulation Violation on State Transitions**: If a method reads
   state to save a "before" snapshot, callers must not mutate that state
   before calling the method.

---

## Debugging Playbook

### WebSocket Issues
1. Check if the issue is protocol-level (Ping/Pong) vs application-level
2. Test in the ACTUAL runtime (browser, not native WS client)
3. Monitor with both server logs and client console simultaneously
4. Verify proxy keepalive settings (Traefik, Cloudflare)

### State Sync Issues
1. Trace the full cycle: action -> state write -> UI read
2. Check if multiple providers manage the same feature
3. Verify the UI watches the provider that the action writes to

### Database Atomicity
1. Check if mutations include ownership validation in WHERE
2. Look for mutate-then-verify patterns (TOCTOU)
3. Test with concurrent requests if possible

### Platform-Specific Bugs
1. Compare implementations line-by-line for behavioral parity
2. Check initialization timing (async race conditions)
3. Verify error handling doesn't silently swallow failures
