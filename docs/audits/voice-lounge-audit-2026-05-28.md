# Voice lounge code audit — 2026-05-28

## Summary

The voice-lounge canvas has stabilised functionally after the 4096-px migration and the i64/i32 server cap fix, but the rapid parallel-PR landing has left two **high-severity** invariant breaks (duplicate drawing-input plumbing + a shared `screenshare-local` window-id collision between participants), one **high-severity** state divergence between client and server for `clear`, plus a scattering of dead code, stale comments, and missing tests for the multi-touch arena fix. None of the findings appear to corrupt persisted data; they are all behavioural / state-consistency issues. Coordinate-space migration is applied consistently in `fromJson` and in the `avatar_move` WS path; image, screenshare, and stroke_partial WS payloads do **not** apply the legacy heuristic, which is intentional for screenshare (CSS pixels) but inconsistent for the other two (see Finding 6).

---

## Findings

### Finding 1 — Duplicate drawing input: `_DrawingLayer` (Listener) and `LoungeDrawingCanvas` (GestureDetector) both fire when a tool is selected
**Severity:** high
**File:** `apps/client/lib/src/widgets/voice_canvas.dart:539-558` (`_DrawingLayer`), `apps/client/lib/src/widgets/lounge_drawing_canvas.dart:43-66`, `apps/client/lib/src/screens/voice_lounge_screen.dart:1249-1260` (Stack composition), `apps/client/lib/src/screens/voice_lounge_screen.dart:1173-1182` (auto-enable `_isDrawing` on tool select)
**Why it's wrong:**
- The voice-lounge Stack puts `LoungeDrawingCanvas(isActive: _isDrawing)` on top of `contentArea`, which already contains the `_DrawingLayer` inside `VoiceCanvas`. `_DrawingLayer` uses a `Listener` with `HitTestBehavior.opaque` whenever `isDrawingTool(tool) || tool == CanvasTool.text` (line 535-538). `LoungeDrawingCanvas` uses a `GestureDetector` with `onPan*` + `HitTestBehavior.opaque`.
- Picking a tool now auto-flips `_isDrawing = true` (voice_lounge_screen.dart 1176-1182). With both `selectedTool != none` AND `_isDrawing == true`, both pointer paths are live.
- Listeners participate in pointer dispatch independently from the gesture arena. Both stacked layers therefore receive `onPointerDown`/`onPointerMove`. Each calls `startStroke` / `continueStroke` / `endStroke`. The second `startStroke` blows away the first's `activePoints` (canvas_provider.dart 187-194: `_pendingStrokePoints = null; _dragId++; activePoints = [point]`). Symptoms include "first sample of a stroke is dropped" and ghost partial-broadcasts on multi-touch end.
- Multi-touch cancellation: `LoungeDrawingCanvas.onPanCancel` calls `endStroke`. But the `_DrawingLayer.Listener` does **not** cancel on multi-touch (it has no recogniser to lose the arena). It keeps firing `onPointerMove` on the surviving pointer, calling `continueStroke` after `endStroke` has already closed the drag — i.e. exactly the regression the `_strokeActive` guard was added for, just from a different angle.

**Recommended fix:** Pick one drawing surface. Either (a) remove `_DrawingLayer`'s pointer handling and rely on `LoungeDrawingCanvas` for every tool (including text-tap), or (b) keep `_DrawingLayer` and stop overlaying `LoungeDrawingCanvas` when `_isDrawing` is true. Option (a) is cleaner because `LoungeDrawingCanvas` already handles the multi-touch arena correctly. Either way, add a widget test that drives two pointers and asserts `startStroke` is called exactly once.

---

### Finding 2 — `windowId: 'screenshare-local'` collides between every participant; remote moves overwrite each client's own local-preview position
**Severity:** high
**File:** `apps/client/lib/src/screens/voice_lounge_screen.dart:475`, `apps/client/lib/src/screens/voice_lounge/lounge_constants.dart:9`, `apps/client/lib/src/screens/voice_lounge/screen_share.dart:362-407` (broadcast + watch)
**Why it's wrong:**
- Every client labels its own local-share preview window with the same constant id `screenshare-local`. The shared canvas state map is keyed by `windowId`, so a single string maps to *one* entry across all participants.
- When peer B drags their local-preview window, B broadcasts `screenshare_move({window_id: "screenshare-local", ...})`. Peer A's `handleCanvasEvent` writes that into `state.screenSharePositions["screenshare-local"]`. A's own local-share window subscribes via `ref.watch(canvasProvider.select((s) => s.screenSharePositions[id]))` (screen_share.dart 397-407) and snaps to B's coordinates.
- Two concurrent screen-sharers therefore yank each other's local preview around. Even one sharer pollutes the entry for everybody else if they have ever had a local preview onscreen.

**Recommended fix:** Either qualify the local-preview id with the local user id (`screenshare-local-${userId}`) so each participant has a unique broadcast key, or stop syncing the local preview entirely — the local preview is arguably a personal viewport overlay, not a shared canvas object. If the design intent is to give each participant freedom to position other participants' shares, the remote-share path (`screenshare-${sid}`) already does that; the local-preview broadcast may be redundant.

---

### Finding 3 — `clearDrawing` and `case 'clear'` wipe **images** client-side, but server `clear` only erases `drawing_data`; late joiners re-fetch ghost images
**Severity:** high (state divergence between live clients and server-persisted truth)
**File:** `apps/client/lib/src/providers/canvas_provider.dart:367-372` (local wipe), `apps/client/lib/src/providers/canvas_provider.dart:816-817` (remote handler wipes images too), `apps/server/src/db/canvas.rs:130-143` (`clear_drawing`), `apps/server/src/ws/events/canvas.rs:33-38` (server dispatches to `clear_drawing`)
**Why it's wrong:**
- Client: tapping "Clear board" sets `state.copyWith(strokes: [], images: [])` and broadcasts `clear`. Remotes receive `clear` and run the same wipe locally (line 817).
- Server: `persist_canvas_state` routes `clear` → `db::canvas::clear_drawing`, which only nukes `drawing_data`; `images_data` is left intact.
- Net effect: every connected participant sees an empty canvas, but the next user to join the channel pulls the persisted `images_data` via `_fetchCanvas` and sees images that no one else has on screen. From that point the canvas state is inconsistent across participants until somebody else `clear`s or `image_remove`s.
- There is also a less-severe asymmetry: `clear_all` exists in the DB layer (line 146-160) but is never called from the event dispatch path.

**Recommended fix:** Make the server-side `clear` event call `clear_all` (drawings + images) so the persistent state matches what the connected clients are doing. Alternatively, leave the server at `clear_drawing` and stop the client from wiping `images` on `clear` — but the existing "Clear board" UI copy promises to remove every drawing AND image (voice_lounge_screen.dart 942-944), so the server is the side that needs to change.

---

### Finding 4 — `_DrawingLayer.Listener` has no gesture-arena participation, so InteractiveViewer pinch can still pan-during-draw on platforms where Listener fires before the arena resolves
**Severity:** medium
**File:** `apps/client/lib/src/widgets/voice_canvas.dart:539-558`
**Why it's wrong:** The whole point of the `LoungeDrawingCanvas` refactor (lounge_drawing_canvas.dart 11-18, dated 2026-05-27) is to use `PanGestureRecognizer` so a second pointer cancels and InteractiveViewer can scale. `_DrawingLayer`'s `Listener.onPointerMove` short-circuits any arena negotiation — it just keeps calling `continueStroke` until pointer-up. So on the code paths where `_DrawingLayer` is the active drawing surface (e.g. the text tool, which `LoungeDrawingCanvas` does not handle because `isDrawingTool(text) == false`), pinch-to-zoom may scale AND draw simultaneously, defeating the May-27 mobile fix for that specific tool.
**Recommended fix:** Either move the text-tool's tap-to-place handling onto the `LoungeDrawingCanvas`/`GestureDetector` path (so the text-tool entry point also benefits from arena cancellation) or wrap `_DrawingLayer`'s pointer handlers in a one-pointer recogniser. Even simpler: if Finding 1 is taken, this disappears because `_DrawingLayer` no longer drives strokes.

---

### Finding 5 — `clearDrawing()` doesn't reset `_myStrokeIds` / `_myImageIds`; subsequent `clearMyDrawings()` mis-counts
**Severity:** medium
**File:** `apps/client/lib/src/providers/canvas_provider.dart:367-372` vs `380-394`
**Why it's wrong:** `clearDrawing` empties `state.strokes` + `state.images` but leaves the local "mine" id sets populated. Next time the user adds a stroke and then taps "Clear my drawings", the function tries to `where((s) => !_myStrokeIds.contains(s.id))` against IDs that no longer exist in state — harmless filter-out — but more importantly the cardinality test `if (_myStrokeIds.isEmpty) return;` is false even though there is no longer any "mine" content on the canvas, so the menu item appears enabled and the user gets a confusing no-op rebroadcast of an empty snapshot.
**Recommended fix:** Clear `_myStrokeIds` and `_myImageIds` at the top of `clearDrawing`. Same when the WS receives a remote `clear` (line 816-817).

---

### Finding 6 — Coordinate-space migration heuristic is **not** applied in WS handlers for `image_add` / `image_move` / `stroke_partial`
**Severity:** medium
**File:** `apps/client/lib/src/providers/canvas_provider.dart:766-810` (`stroke_partial` builds `CanvasPoint` raw; lines 818-829 (`image_add` / `image_move` call `CanvasImage.fromJson` which **does** migrate — OK there). However `stroke_partial` (lines 766-773) builds points via `CanvasPoint(x: ..., y: ...)` without `_migrateLegacyCoord`.
**Why it's wrong:** A legacy client that still emits normalised stroke_partial frames (pre-4096 build) will paint partial strokes inside the top-left 1 px after the receiver upgrades. The final `stroke` event will migrate correctly via `CanvasStroke.fromJson`, so the stroke "jumps" from the corner to the right place on pointer-up. This makes mixed-version sessions visibly broken during live drawing. The `avatar_move` handler already applies the inline migration (lines 848-849); apply the same heuristic to `stroke_partial`.

The audit prompt asked to verify "image_move applies migration on the WS path too". It does: `image_add` and `image_move` both call `CanvasImage.fromJson` which migrates — that's fine. The gap is `stroke_partial`.

**Recommended fix:** Wrap the `stroke_partial` point construction in the same `value <= 1.0 ? value * kCanvasWidth : value` heuristic the avatar handler uses, or hoist a top-level `_migrateLegacyCoord` helper into the canvas-provider scope so all four WS sites use the same function.

---

### Finding 7 — Image bounds clamp uses `kCanvasWidth` as max for the left edge; lets images be dragged fully off-canvas
**Severity:** medium
**File:** `apps/client/lib/src/widgets/voice_canvas.dart:433-434`
**Why it's wrong:** `final newX = (curX + dx).clamp(0.0, kCanvasWidth);` allows x to reach 4096 (right edge of canvas), but Positioned uses `left: img.x, width: img.width`, so the image's left edge anchored at x=4096 puts the whole image off the right side. The clamp should be `kCanvasWidth - img.width` (and similarly for y). The resize path has the same issue (lines 457-458) but is bounded by a minimum width 32 so it's less dramatic.
**Recommended fix:** Clamp to `(0, kCanvasWidth - img.width)` and `(0, kCanvasHeight - img.height)`; guard against width > canvas (treat as no-clamp). Apply the same fix in `CanvasController.moveImage` so WS-received moves are also constrained on the receiver.

---

### Finding 8 — Server accepts arbitrary numeric coordinates; no clamp / range validation matches client's 4096-px space
**Severity:** medium
**File:** `apps/server/src/ws/events/canvas.rs:130-193`, `apps/server/src/db/canvas.rs` (whole file)
**Why it's wrong:** The server stores the raw JSON payload and only validates `kind`. Nothing prevents a malicious client from posting `{"x": 1e18, "y": -1e18}` or strokes with millions of points (each frame is capped at 64 KB by the WS guard mentioned in canvas.rs:41-43, but a stroke of e.g. 200 points × 30 bytes/point is well within 64 KB). The cap is on stroke count, not stroke size. A connected attacker could plant strokes with NaN/Inf coords that crash the client painter.
**Recommended fix:** Define a server-side `MAX_CANVAS_EXTENT = 4096` (or `8192` for headroom) constant and validate `payload.points[*].x/y`, `payload.x/y/width/height` are finite and within `[-MAX, MAX]` before persisting. Reject events whose `points` arrays exceed a sensible cap (say 4096 points per stroke). Same client-side too — the client's `clamp(0, kCanvasWidth)` is a safety net but it only fires on local input, not on receive.

---

### Finding 9 — `moveLocalAvatar` / `commitLocalAvatarMove` are dead aliases
**Severity:** low
**File:** `apps/client/lib/src/providers/canvas_provider.dart:553-554, 644-645`
**Why it's wrong:** Both are documented as "back-compat alias" but ripgrep finds no callers outside their own definitions. Stale shim from the per-user → shared-whiteboard rename.
**Recommended fix:** Delete both methods and the comment that references "the rename in flight". Mirror update in any docs.

---

### Finding 10 — `_handlePasteImage` doesn't actually paste image bytes; the name overpromises
**Severity:** low
**File:** `apps/client/lib/src/widgets/voice_canvas.dart:482-493`
**Why it's wrong:** Reads `Clipboard.kTextPlain` and bails unless the text starts with `http://` / `https://`. A user who copies an actual image (e.g. from a screenshot tool) sees nothing happen on Ctrl-V. Either name is wrong or implementation is incomplete.
**Recommended fix:** Either rename to `_handlePasteImageUrl` and update the comment + log, or add a `super_clipboard` / `pasteboard`-style fallback to read image bytes, upload via the media route, and call `_addImageFromUrl` with the resulting URL.

---

### Finding 11 — `PuckTrail.render` API doc and signature still talk about normalised 0..1 coords; the only caller now feeds canvas pixels and forces `canvasSize: Size(1, 1)` to neutralise the multiplication
**Severity:** low
**File:** `apps/client/lib/src/widgets/puck_trail.dart:72-99`, used at `apps/client/lib/src/widgets/voice_canvas.dart:1022-1032`
**Why it's wrong:** The method multiplies `(s.pos.x - current.x) * canvasSize.width`. In the pre-migration world this turned a 0..1 delta into pixels. Today the caller passes raw canvas-space pixel deltas and a `Size(1, 1)` to neutralise the multiplication. Any future caller that passes a real `canvasSize` will multiply pixel deltas by 4096 and paint trail samples thousands of pixels off-screen.
**Recommended fix:** Drop the `canvasSize` parameter from `PuckTrail.render` (it no longer makes sense in pixel space) and remove the `Size(1, 1)` hack at the caller. Update the API doc to say "absolute canvas-space pixels" instead of "normalised".

---

### Finding 12 — `_DraggableAvatar.currentPos` docstring still says "Current normalized position [0,1] on the canvas"
**Severity:** low
**File:** `apps/client/lib/src/widgets/voice_canvas.dart:761`, and the surrounding local variable `normalized` at lines 326-376
**Why it's wrong:** Comment is now wrong (post-4096 migration values are absolute pixels). The local variable `normalized` is misleading. Future maintainers will assume the value is 0..1 and multiply by some viewport size.
**Recommended fix:** Update the docstring to "absolute canvas-space pixel position" and rename the local from `normalized` to `pixelPos` or just `position`.

---

### Finding 13 — `_strokeActive` guard correctly drops late ticks, but no widget test asserts it on the gesture-arena cancel path
**Severity:** low (test coverage gap)
**File:** `apps/client/test/providers/canvas_provider_test.dart` exercises the timer/`debugFlushStrokePoints` path, but no test drives a two-pointer arena-cancel on `LoungeDrawingCanvas` to confirm `endStroke` runs from `onPanCancel`.
**Recommended fix:** Add a widget test that wraps `LoungeDrawingCanvas` in a fake `InteractiveViewer` (or just exercises the gesture-arena directly with `WidgetTester.startGesture` × 2) and asserts the stroke ends + `_strokeActive` flips false after the second pointer arrives.

---

## Did NOT find

The following were checked and look correct given the current invariants:

- **Throttle cancellation on `detach()`** — every timer in `_strokeThrottle`, `_avatarThrottle`, `_imageThrottle`, `_screenShareThrottle` is cancelled and its pending payload nulled (canvas_provider.dart 110-128). `_strokeActive` is reset. `_dragId` is intentionally not reset (it's a monotonic stamp; not resetting is correct).
- **Coordinate migration in `CanvasPoint.fromJson` / `CanvasImage.fromJson`** — applied via `_migrateLegacyCoord`. The same heuristic is inlined in `avatar_move` WS handler (canvas_provider.dart 846-849). Both `_fetchCanvas` and `handleCanvasEvent` route through these.
- **WS event-kind compatibility** — every client `_sendCanvasEvent` kind (`stroke`, `stroke_partial`, `clear`, `image_add`, `image_move`, `image_remove`, `avatar_move`, `screenshare_move`) is in the server's `VALID_KINDS`. No orphans either way.
- **Late stroke-end / `_dragId` regression** — the explicit `_strokeActive = false` + atomic cancel at the start of `endStroke` (canvas_provider.dart 334-345) prevents the documented late-partial replay. `startStroke` defensively re-cancels and bumps `_dragId` before any state mutation.
- **`attach()` race window** — promotion order is correct: `_attachingChannelId` is set first, state is reset, snapshot is fetched, then `_channelId` is promoted only if we haven't been superseded. Buffered events (`_pendingEvents`) are replayed after promotion (canvas_provider.dart 86-107).
- **Avatar/screenshare receiver target-id** — `handleCanvasEvent` `avatar_move` keys off `payload['user_id']` with a fallback to `from_user_id` for legacy clients (line 841). `screenshare_move` keys off `payload['window_id']` (line 868) — there is no fallback to sender, which is correct because the windowId is a stable per-stream id (modulo Finding 2).
- **i32 vs i64 cap-decode** — fixed in both `append_stroke` and `add_image` (canvas.rs 71-82, 174-185), and both now widen via `i64::from(...)` at the comparison.
- **`persist_canvas_state` swallow-error paths** — every `_` arm logs and returns `true` so the broadcast still happens, which is the documented behaviour: persistence is best-effort, relay is mandatory. Within that contract there is no other `Ok(false)` foot-gun I could find.

---

## Adjacent risks (out of strict scope but worth flagging)

- **No size cap on `_pendingEvents`** (canvas_provider.dart:56) — a peer flooding strokes during another peer's slow REST fetch could grow the buffer unbounded. Cap to ~256 events with a drop-oldest policy.
- **`addTextLabel` never bumps `_strokeActive`** — fine because text isn't a drag, but it also doesn't dedupe against an in-flight drag. A user could (in theory) start drawing a line, swap to the text tool mid-drag, tap to add a label, and the original drag's `_strokeActive` would still be set. `endStroke` would then commit a partial line. Unlikely in practice because the toolbar swap happens via the menu, but worth a one-line guard.
- **`importSnapshot` re-broadcasts other participants' strokes under the caller's `from_user_id`** (canvas_provider.dart 406-419) — server doesn't persist sender per-stroke so this is harmless today, but if attribution is ever added (e.g. for per-author undo or moderation), this path would mis-attribute. Consider tagging the broadcast with the original sender id, or restricting `importSnapshot` to strokes the caller authored.
- **`MAX_STROKES = 2000` per channel is shared across all participants and a session has no rollover** — a busy whiteboard will hit the cap and start hard-failing for the next user. Consider rolling the oldest strokes off on overflow instead of returning `CapReached`, or surface the count in the UI so users know they're approaching the limit.
- **`voice_lounge_screen.dart` is 1500 lines** and `voice_canvas.dart` is 1420. Several SonarCloud budgets (S3776 cognitive complexity, S107 param counts on the avatar helpers) are likely already breached on the avatar-build chain (`_buildAvatarWidget` → `_DraggableAvatar` → `_DraggableAvatarState.build` → nine helpers). Worth a follow-up split — not part of this audit but the recent PR churn made it worse.
