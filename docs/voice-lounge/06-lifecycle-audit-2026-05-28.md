# Voice-lounge lifecycle audit — 2026-05-28

Follow-up to PR #1262 (debounced leave button). The user continued to hit
crashes on lounge join/leave on Android despite the leave-button latch.
This audit walked every `await`, `Timer`, `Stream` subscription, post-frame
callback, and `ref.read` in the voice-lounge join → use → leave flow and
fixed the lifecycle gaps that survived #1262.

## Files audited

- `lib/src/screens/voice_lounge_screen.dart`
- `lib/src/screens/voice_lounge/floating_dock.dart`
- `lib/src/screens/voice_lounge/screen_share.dart`
- `lib/src/widgets/voice_lounge/encrypted_canvas_notice.dart`
- `lib/src/widgets/lounge_drawing_canvas.dart`
- `lib/src/widgets/voice_canvas.dart`
- `lib/src/providers/canvas_provider.dart`
- `lib/src/providers/canvas_authority_provider.dart`
- `lib/src/providers/livekit_voice/livekit_voice_provider.dart`
- `lib/src/providers/screen_share_provider.dart`
- `lib/src/providers/voice_lounge_fullscreen_provider.dart`

## Fixes shipped in this audit

### 1. FloatingDock `_handleLeave` — `ref.read` after dispose (Crash on leave)

`_handleLeave` did three sequential `await`s and called `ref.read(...)`
*after* each one. If the dock's `ConsumerState` was disposed mid-await
(parent `HomeScreen` swapped lounge ↔ chat, Android foreground-service
`ACTION_LEAVE` fired alongside the UI tap, iOS CallKit hang-up race),
the post-await `ref.read` threw `StateError: Cannot use "ref" after the
widget was disposed` and the second leave path crashed silently inside
the awaited future — leaving the LiveKit room undisposed and the server
session row stale.

Fix: capture all three notifier handles into local variables *before*
the first await. The notifiers are keepAlive providers so the handles
stay valid across the dock's lifetime.

Repro: `test/screens/voice_lounge/lifecycle/floating_dock_leave_after_dispose_test.dart`.
Verified RED → GREEN against the fix.

### 2. CanvasController `_fetchCanvas` — stale state write after detach (Stale state)

`attach()` awaited an HTTP fetch and the fetch's success / non-200 / catch
branches wrote `state = state.copyWith(...)` unconditionally. If the user
left the lounge while the GET was in flight, `detach()` ran first, cleared
state to `const CanvasState()`, and then the resolving fetch overwrote the
cleared state — silently re-populating strokes or flipping `isLoaded: true`
on a logically-detached canvas.

Fix: gate every state write inside `_fetchCanvas` on
`_attachingChannelId == channelId`. The outer `attach()` already had this
guard but it ran after the writes, not before them.

Repro: `test/screens/voice_lounge/lifecycle/canvas_attach_detach_race_test.dart`.
Verified RED → GREEN against the fix.

### 3. VoiceLoungeScreen `_confirmClearBoard` — `ref.read` after dispose (Crash during use)

`_confirmClearBoard` awaited `showEchoConfirmDialog` and then called
`ref.read(canvasProvider.notifier).clearDrawing()` without checking
`mounted`. If the lounge unmounted while the confirm dialog was visible
(rare but reachable through HomeScreen layout flips), the `ref.read`
threw post-dispose.

Fix: add `if (!mounted) return;` between the await and the `ref.read`.

## Verified-clean lifecycle surfaces

These paths were audited and judged safe — kept here so future incident
investigators don't re-walk the same ground:

- `VoiceLoungeScreen.dispose` uses the `StateController` handle captured
  in `initState` rather than `ref.read` — already correct for the
  Riverpod dispose contract.
- `VoiceLoungeScreen.initState` post-frame for the encrypted-canvas
  popup is `mounted`-guarded (PR #1269).
- `VoiceLoungeScreen.build` post-frames for `_interactiveViewportSize`
  and `_viewportInitialised` are `mounted`-guarded.
- `VoiceLoungeScreen._pickBackground` has `mounted` guards on every
  context use after its multiple awaits.
- `CanvasController.detach` cancels every `Timer` (`_avatarThrottle`,
  `_imageThrottle`, `_strokeThrottle`, `_screenShareThrottle`,
  `_perfLogTimer`) and the `ref.onDispose` callback cancels them again
  as a belt-and-suspenders.
- `LiveKitVoiceNotifier.leaveChannel` has `_isLeaving` latch (PR #1262)
  plus `_disposed` checks on every state-writing room-event handler.
- `_AspectAwareVideoTrackState._initRenderer` checks `mounted` after
  the async `renderer.initialize()` and disposes the orphan renderer.
- `ScreenShare.stopScreenShare` checks `_disposed` before its state
  write.
- The notification + CallKit leave paths both go through the same
  guarded `leaveChannel`.

## Open risks (NOT fixed in this audit, documented for follow-up)

- `_pendingScreenShareViewport` field is referenced only inside
  `_flushScreenShareMove` / `commitScreenShareMove` and is currently
  cleared only on the commit path. If the throttle ticker fires after
  a commit without a subsequent `moveScreenShare`, `_pendingScreenShare`
  is already nullified so the early-return guards it — no crash, but
  worth re-walking if a future change adds another writer.
- `CanvasController._perfLogTimer` starts at the *end* of `attach()`. If
  `attach()` is awaiting the fetch and a `detach()` runs first, the
  fixed guard now bails before the timer starts — confirmed correct.
- The `voice_lounge_screen.dart::build` writes to `_viewportInitialised`
  during build (not after a post-frame). This is a Flutter anti-pattern
  but doesn't crash; it just makes builds non-idempotent. Refactoring it
  is out of scope for a crash-hygiene audit.

## Trace path back to user report

User reported: "crashes on lounge join/leave on Android, despite the
#1262 debounce fix". The audit confirmed two real crash paths and one
state-pollution path that survived #1262. All three have regression
tests and the fixes are scoped to the minimum diff needed.
