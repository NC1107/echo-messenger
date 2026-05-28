# 02 — Input matrix

## Status quo

The lounge canvas uses an `InteractiveViewer` for pan/zoom and a `LoungeDrawingCanvas` `GestureDetector` overlay for stroke capture. Recent fixes (#1247, #1257, #1266) tuned gesture-arena handoff but no written contract exists for how each input device class should behave. Implementation decisions have been ad-hoc per-bug.

## Decision matrix

Per device class, per action. Conflict rules at the bottom.

### Touch (phone, tablet)

| Action | Gesture | Notes |
|---|---|---|
| Pan | One-finger drag | Only when `selectedTool == CanvasTool.none` (no active draw tool) |
| Zoom | Pinch (two fingers) | Always available — pinch wins arena over draw via the slop-based `PanGestureRecognizer` handoff (`lounge_drawing_canvas.dart:42`) |
| Draw | One-finger drag | Only when a draw tool is selected; ~18 px slop before claim |
| Select an object (avatar, image) | Tap | Tool-agnostic |
| Double-tap zoom (zoom in 2× at point) | Two quick taps | Only when `selectedTool == CanvasTool.none`. Disabled while a draw tool is active (#1266) |
| Tool-cancel / exit draw mode | Tap the active tool button again | Currently routed through `_toggleDrawingMode()`; deselects + clears `selectedTool` |

### Mouse (Linux/Windows/macOS desktop, web with mouse)

| Action | Gesture | Notes |
|---|---|---|
| Pan | Middle-click drag, OR left-click drag with no tool selected | Same `selectedTool == none` gate as touch |
| Zoom | `Ctrl/Cmd + scroll wheel` | Wheel without modifier scrolls page / nothing |
| Draw | Left-click drag | Same slop-based handoff as touch |
| Select an object | Left-click | |
| Double-tap zoom | Double-click | Same `selectedTool == none` gate. Double-click while drawing is **explicitly suppressed** (#1266 fix) |
| Tool-cancel | Right-click OR Escape | Right-click currently has no canvas handler; this is a future addition |

### Trackpad (laptop touchpad)

| Action | Gesture | Notes |
|---|---|---|
| Pan | Two-finger drag | Same as scroll; no modifier |
| Zoom | Pinch-to-zoom (built-in trackpad gesture) OR `Ctrl/Cmd + scroll` | Trackpad pinches arrive as scale events |
| Draw | One-finger drag | Click-and-drag; same slop handoff |
| Select | One-finger tap | |
| Double-tap zoom | Double-tap (one finger) | Same gate |

### Keyboard (all devices with hardware keyboard)

| Action | Keys | Notes |
|---|---|---|
| Reset view (fit-to-content) | `0` or `Cmd/Ctrl+0` | Resets to `_centeredPose` |
| Zoom in | `Cmd/Ctrl + +` | 1.25× current scale |
| Zoom out | `Cmd/Ctrl + -` | 0.8× current scale |
| Pan | Arrow keys | 100 canvas-pixels per press; `Shift+Arrow` = 500 |
| Cancel draw / clear selection | `Escape` | Same as right-click |
| Cycle tools | `B` (brush) / `E` (eraser) / `T` (text) / `Escape` (none) | Single-letter, no modifier; only active when canvas has focus |

## Conflict rules

These apply across all device classes; they exist to make gesture-arena behavior predictable instead of emergent.

1. **A draw stroke in progress wins all other gestures** — pinch, double-tap, double-click, scroll-wheel zoom are all suppressed for the duration of the stroke (from `onPanStart` to `onPanEnd` / `onPanCancel`). This is the rule that today's #1266 fix encodes.
2. **A second simultaneous pointer cancels a draw stroke and yields to the pinch/scale recognizer.** Implemented today via the slop-based `PanGestureRecognizer` losing the arena to `ScaleGestureRecognizer` once it sees the second pointer (`lounge_drawing_canvas.dart:42`). This is the rule that today's #1257 fix encodes.
3. **`selectedTool == CanvasTool.none` means pan/zoom is unrestricted; any tool selected means pan/zoom are still possible but require the gesture to *not* trigger a draw first.** Practically: pinch always pans/zooms; single-pointer drag draws only if a tool is active.
4. **Tool switching is destructive** — switching from brush to eraser mid-stroke cancels the in-flight stroke (no half-finished strokes get committed). Already implemented via `endStroke` on tool change.
5. **Focus is required for keyboard shortcuts** — the canvas must have keyboard focus (clicked into) before `B`/`E`/`T`/`Escape` cycle tools. Same model as Figma. Single-letter shortcuts must not fire while the chat input has focus.

## Acceptance criteria

- A PR that adds a new gesture (or changes an existing one) must update the matrix above before the behavior change merges.
- Any new gesture must declare its arena precedence relative to draw, pinch-zoom, and double-tap. "It just works in testing" is not a precedence declaration.
- The keyboard shortcuts column is the contract for `Shortcuts`/`Actions` widget keymaps; new shortcuts must not collide with existing single-letter keys without a written justification.

## Open questions

- **Pen / stylus support** — currently treated as touch. iPad pencil / Wacom may want pressure-sensitive stroke width. Pickup trigger: tester with a stylus reports unsatisfying stroke quality.

## Confirmed by review (2026-05-28)

- **Right-click on canvas = cancel draw / clear selection** (same as Escape). No full context menu in v1; defer Cut/Copy/Paste/z-order until first feature request.
- **Trackpad scroll-wheel zoom stays modifier-required** (Ctrl/Cmd + scroll). Unmodified two-finger scroll pans. Predictable across web + desktop; revisit if testers report friction.
