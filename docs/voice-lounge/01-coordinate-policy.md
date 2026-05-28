# 01 — Coordinate policy

## Status quo

Three canvas entity classes, **three different coordinate models**:

| Entity | Coordinate space | Wire format | Code |
|---|---|---|---|
| **Strokes** (freehand, shapes, text) | Canvas-world, absolute pixels in 100 000 × 100 000 surface | Absolute pixels, with `_migrateLegacyCoord` heuristic accepting ≤ 1.0 as legacy 0..1 normalized (multiplied by **4096**, not 100k) | `canvas_models.dart:37`, `apps/server/src/db/canvas.rs` |
| **Avatars** | Canvas-world, absolute pixels in 100 000 × 100 000 surface, default ring radius `0.3 × kCanvasWidth ≈ 30 000 px` | Same as strokes; keyed by `user_id` | `voice_canvas.dart:385`, `canvas_provider.dart:534` |
| **Screen-share windows** | **Viewport-relative CSS pixels** (clamped against the receiving InteractiveViewer's `LayoutBuilder` constraints) | Raw CSS pixels `{window_id, x, y, width, height}` — explicitly NOT normalized, comment in `canvas_provider.dart:646` | `screen_share.dart:402-422`, `canvas_provider.dart:691,719` |

### The cross-device divergence bug this creates

Sender on a 1920×1080 desktop drags a screen-share window to `x = 1500, y = 200`. The `screenshare_move` payload broadcasts those raw values. A receiver on a 390×844 phone reads `_left = shared.x = 1500`, then `LayoutBuilder` immediately clamps to `min(constraints.maxWidth - 60) = 330`. The window snaps to the right edge of the phone, nowhere near where the sender intended it.

This is a coordinate-space leak: sender's local viewport pixels are being treated as a universal coordinate, but only the receiver's viewport gives them meaning.

Avatars and strokes don't have this bug because they live in canvas-world coordinates, and every device renders the same 100k surface through its own InteractiveViewer transform.

## Options

### Option A — Unify everything to canvas-world

Screen-share windows become canvas objects in 100k space.

- **Pro:** one coord model; cross-device parity for free.
- **Con:** screen-share windows are conceptually a UI overlay, not a whiteboard primitive. Putting them in the 100k surface means they zoom and pan with the canvas — a participant zooming into a stroke would zoom out of the screen share. That's bad UX. It also means we lose the ability to keep screen share visible during a stroke focus.

### Option B — Normalize the screen-share wire format

Screen-share windows stay viewport overlays *locally*, but the wire format is normalized 0..1 of "lounge interactive viewport". Sender divides by their `_interactiveViewportSize`; receiver multiplies by their own `_interactiveViewportSize`.

- **Pro:** cross-device parity. Screen-share keeps overlay semantics (no zoom-with-canvas). Minimal new code — a translation layer in `canvas_provider.dart` send/receive paths plus a viewport-size sentinel on each end.
- **Con:** the receiver might have a wildly different aspect ratio. A window pinned to the top-right on a 1920×1080 desktop will appear top-right on a phone too — but proportionally taller/narrower. Acceptable for overlay UX; can be refined per-aspect-ratio later if needed.

### Option C — Keep hybrid; document the divergence as deliberate

Each device's screen-share window position is intentionally local. Wire format goes away entirely; positions are not synchronized.

- **Pro:** simplest. Each user arranges their own view.
- **Con:** kills shared-pointing UX ("look at this thing in the upper-left of your screen share"). The current `screenshare_move` synchronization exists because that UX was wanted.

## Decision

**Option B**, dated 2026-05-28.

Wire format for `screenshare_move` becomes `{window_id, x_norm, y_norm, w_norm, h_norm}` with values in `[0.0, 1.0]` of the sender's interactive viewport. Receiver multiplies by its own `_interactiveViewportSize` before applying. A `coord_v` field on the event distinguishes the new format from legacy CSS-pixel payloads (legacy continues to be accepted via a translation shim until Phase 4's sunset gate fires).

Avatars and strokes stay in canvas-world coordinates with no changes.

The stroke coord migration heuristic (`_migrateLegacyCoord`) is **not** revisited here; Phase 4 (legacy migration sunset) owns that decision.

## Acceptance criteria

- Any PR that introduces a new canvas entity must place it in one of the two documented coord spaces (canvas-world for whiteboard-like content, normalized-viewport for overlay-like content) and state which in the PR description.
- Any change to `screenshare_move` payload shape must bump `coord_v` and provide a translation shim for the previous version.
- No PR may reintroduce raw-CSS-pixel coordinates as a wire format for any entity that synchronizes across devices.

## Open questions

- **Per-aspect-ratio refinement for screen-share overlay placement** — the normalization treats a 16:9 desktop and a 9:19 phone identically, which is good enough for v1 but may want a future "anchor + offset" model (`{anchor: 'top-right', x_offset_norm: 0.05}`). Pickup trigger: tester reports that proportional placement looks wrong on a particular device class.

## Confirmed by review (2026-05-28)

- **Resize sync uses the same viewport-normalization as position.** `w_norm` and `h_norm` ride in 0..1 of the sender's viewport. The receiver multiplies by its own viewport size **and** clamps to a `w_min_px` / `h_min_px` floor (120 px) so phone-side windows don't shrink below readable size. This preserves "looks proportional across devices" while preventing the worst-case "tiny window on a phone" outcome.
- **Strokes, shapes, avatars are unchanged.** They live in canvas-world (100k) coordinates and zoom/pan with the InteractiveViewer transform, so they already appear in the same logical position on every device. The resize-sync change only affects the screen-share window overlay, not whiteboard content.
