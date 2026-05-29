# 05 — Canvas rewrite spec

> **Reference research informing this doc**
> - tldraw — [Draw shape docs](https://tldraw.dev/sdk-features/draw-shape), [Geo shape docs](https://tldraw.dev/sdk-features/geo-shape), [Event handling reference](https://deepwiki.com/tldraw/tldraw/3.3-asset-management), [Force mobile layout example](https://tldraw.dev/examples/force-mobile)
> - Excalidraw — [Perfect-freehand PR #3512](https://github.com/excalidraw/excalidraw/pull/3512), [Touch device meta-issue #9705](https://github.com/excalidraw/excalidraw/issues/9705), [Pan with one finger in pen mode #8785](https://github.com/excalidraw/excalidraw/issues/8785), [Hand tool announcement](https://x.com/excalidraw/status/1618274234014498818)
> - Figma / FigJam — [FigJam for iPad](https://help.figma.com/hc/en-us/articles/4502073572247-FigJam-for-iPad), [Pan and zoom in FigJam](https://help.figma.com/hc/en-us/articles/1500004414582-Pan-and-zoom-in-FigJam), [Shape tools](https://help.figma.com/hc/en-us/articles/360040450133-Shape-tools)
> - Miro — [Pen tool help](https://help.miro.com/hc/en-us/articles/360017730573-Pen), [Tablet app help](https://help.miro.com/hc/en-us/articles/360017731633-Tablet-app), [Palm-rejection announcement](https://community.miro.com/product-news-31/pen-tool-updates-palm-rejection-highlighter-lasso-tool-and-drawing-presets-2536)
> - Apple Freeform — [Draw or handwrite on a Freeform board on iPad](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0)
> - perfect-freehand — [steveruizok/perfect-freehand (algorithm)](https://github.com/steveruizok/perfect-freehand), [perfect_freehand pub.dev](https://pub.dev/packages/perfect_freehand)
> - Flutter packages — [scribble](https://pub.dev/packages/scribble), [flutter_drawing_board](https://pub.dev/packages/flutter_drawing_board), [InteractiveViewer API](https://api.flutter.dev/flutter/widgets/InteractiveViewer-class.html)
> - Stroke modelling background — [google/ink-stroke-modeler](https://github.com/google/ink-stroke-modeler)

## TL;DR

- **Recommended path: B — targeted rewrite.** Keep the existing 4096×4096 canvas-world model, WS sync layer, multi-device authority, and tool set. Replace the two layers that produce the bad mobile feel: the gesture/transform layer and the stroke painter.
- **Top 3 changes:** (1) replace `InteractiveViewer` with a custom `Listener`-driven transform controller (pointer-count branching: 1-pointer-with-tool = draw, 1-pointer-no-tool = pan, 2-pointer = pinch/pan, mid-stroke 2nd pointer = cancel stroke and yield); (2) split the painter into three layered `RepaintBoundary`s — background, committed strokes, in-flight stroke — so mid-stroke frames only repaint a single short polyline; (3) route in-flight strokes through `perfect_freehand` for velocity-thinned smooth output, with raw points still the wire format.
- **Estimated effort:** 5–8 person-days. ~2 days for the gesture/transform layer, ~2 days for the painter split + smoothing, ~1 day for the mobile toolbar collapse, ~1–2 days for tests and the lounge-join/leave crash fix that audit batch B left behind.
- **What the user sees:** stroke latency drops on phones (no per-point Riverpod rebuild of the whole canvas subtree); pinch-to-zoom never fights a stroke; strokes look smooth instead of polygonal; the bottom dock collapses to a single floating button on phone-portrait so the canvas isn't cramped.
- **Hardest part / biggest risk:** correctly cancelling an in-flight stroke when a second pointer arrives, without dropping the last few sampled points on the committed stroke. Excalidraw and tldraw both ship subtle bugs in this corner ([Excalidraw #9945](https://github.com/excalidraw/excalidraw/issues/9945)), and the existing slop-based handoff (`lounge_drawing_canvas.dart:42`) already papers over this. The rewrite needs a deterministic state machine, not slop heuristics.

## Status quo

The canvas is a 4096×4096 (formerly 100k; reduced per #1253) `SizedBox` wrapped by `InteractiveViewer`, with a `Positioned.fill(LoungeDrawingCanvas)` overlay layered on top of `_DrawingLayer` (CustomPainter for committed strokes + avatars + images). Mobile users report:

- Lounge join/leave crashes (separate bug — out of canvas-redesign scope but tracked here as a blocker).
- "Poor canvas movement" — `InteractiveViewer.panEnabled = !_isDrawing` is the only switch; tool selection toggles pan-enabled at the viewer, but single-pointer-while-tool-active still has to win an arena fight against the viewer's pan recogniser via `kPanSlop`-driven `DragStartBehavior.start` on the overlay (`lounge_drawing_canvas.dart:39-67`). That's the source of the ~18 px dead-zone before strokes start.
- Strokes look polygonal at low scroll velocity. The painter does `Path.lineTo` between every sampled point with no smoothing (`voice_canvas.dart:684-691`).
- Every `continueStroke` does `state = state.copyWith(activePoints: pts)` (`canvas_provider.dart:253`), which causes every `ref.watch(canvasProvider)` consumer — the entire `_DrawingLayer` plus the dock plus tool buttons — to rebuild and repaint. There is **one** `RepaintBoundary` around the painter (`voice_canvas.dart:543`) and **none** isolating in-flight from committed strokes, so each new sample repaints the union of every prior stroke on the board.
- Double-tap zoom while drawing zooms (#1266 fix added a defensive `null` on `onDoubleTapDown` when `_isDrawing` is true, but the bug type — gesture-arena emergence rather than declared semantics — keeps producing similar regressions).
- The bottom dock + tool ribbon + members panel eat ~40 % of vertical space on a 390×844 phone-portrait viewport, so the actual drawing area is ~390×500 — too small to feel like a canvas.

## Reference research

Concrete, citable behaviour from the five products the user named. Where a product's behaviour is not documented and not obvious from the codebase, the row is marked "not documented" rather than guessed.

| Behaviour | Figma / FigJam | Miro | Apple Freeform | Excalidraw | tldraw |
|---|---|---|---|---|---|
| One-finger, no tool | Pan (drag with one or two fingers). [Source](https://help.figma.com/hc/en-us/articles/4502073572247-FigJam-for-iPad) | Pan / select an object — depending on what's under the finger. [Source](https://help.miro.com/hc/en-us/articles/360017730573-Pen) | Pan and select. [Source](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0) | Pan only when the dedicated **hand tool** is selected, else select. [Source](https://x.com/excalidraw/status/1618274234014498818) | Pan with the hand tool; otherwise select / shape-specific. [Source](https://tldraw.dev/sdk-features/draw-shape) |
| One-finger, draw tool active | Draws. Use two fingers to pan instead. [Source](https://help.figma.com/hc/en-us/articles/4502073572247-FigJam-for-iPad) | Draws. [Source](https://help.miro.com/hc/en-us/articles/360017730573-Pen) | Draws with finger (Apple Pencil opt-in too). [Source](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0) | Draws. Two-finger panning still works alongside. [Source](https://github.com/excalidraw/excalidraw/issues/8785) | Draws. [Source](https://tldraw.dev/sdk-features/draw-shape) |
| Two-finger gesture | Pan + pinch-zoom simultaneously. [Source](https://help.figma.com/hc/en-us/articles/4502073572247-FigJam-for-iPad) | Pan + pinch (community-confirmed; Miro's official position is "one touchpoint per display" but the iPad app supports two for pan/zoom). [Source](https://community.miro.com/ask-the-community-45/drawing-with-pen-on-smartboard-and-one-finger-12140) | Pan + pinch. Rotate via two-finger rotate gesture. [Source](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0) | Pan + pinch (pen mode disables touch-zoom). [Source](https://github.com/excalidraw/excalidraw/issues/8785) | Pan + pinch. [Source](https://deepwiki.com/tldraw/tldraw/3.3-asset-management) |
| Mid-stroke second pointer | Cancels stroke; second pointer initiates pan/zoom. (Inferred from FigJam iPad guidance "use two fingers to move while drawing".) | Closes the pen toolbar, treats as zoom. Documented annoyance — strokes are not always cancelled cleanly. [Source](https://community.miro.com/ideas/gestures-pen-tool-and-post-its-7506) | Not documented; inferred-cancel from user reviews. | Cancels in pen mode; bug reports for mixed-input edge cases ([Excalidraw #9945](https://github.com/excalidraw/excalidraw/issues/9945)). | Cancels stroke and hands off to pinch. [Source](https://deepwiki.com/tldraw/tldraw/3.3-asset-management) |
| Double-tap | Zoom to fit a frame (Figma design); FigJam: select / deselect. [Source](https://forum.figma.com/archive-21/double-tap-click-interaction-30795) | Not documented as a canvas gesture. | Not documented. | No documented double-tap zoom. | Zoom into / out of a shape (configurable via SDK). |
| Long-press | Context menu in Figma design; not in FigJam mobile. | Context menu / multi-select. | Not documented. | Not documented. | Context menu for shape options. |
| Stroke smoothing | Not documented (FigJam pen tool is intentionally simple). | "Smart drawing" auto-straightens but underlying smoothing is undocumented. | "Hold steady at end" gesture snaps to shape; smoothing during stroke is undocumented. [Source](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0) | **perfect-freehand** (streamline + curve fit). [Source](https://github.com/excalidraw/excalidraw/pull/3512) | Streamline + smoothing + velocity-based thinning. [Source](https://tldraw.dev/sdk-features/draw-shape) |
| Pressure sensitivity | Apple Pencil: yes; finger: no. [Source](https://help.figma.com/hc/en-us/articles/4502073572247-FigJam-for-iPad) | Yes for Apple Pencil / S Pen; finger uses fixed width. [Source](https://community.miro.com/product-news-31/pen-tool-updates-palm-rejection-highlighter-lasso-tool-and-drawing-presets-2536) | Yes for Apple Pencil. [Source](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0) | Yes for pen; simulated via velocity for mouse. [Source](https://github.com/steveruizok/perfect-freehand) | Yes for pen (via `isPen`); velocity-simulated for mouse/finger. [Source](https://tldraw.dev/sdk-features/draw-shape) |
| Snap-to-grid | Opt-in. | Opt-in. | "Snap to shape" smooths hand-drawn lines into geometry. [Source](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0) | Opt-in. | Opt-in. |
| Infinite canvas | Yes, unbounded both axes. | Yes, unbounded. | Yes (unbounded scroll). | Yes (unbounded). | Yes (unbounded). |
| Mobile cramped UI | FigJam iPad: bottom toolbar collapses; "Done" exits a tool. [Source](https://help.figma.com/hc/en-us/articles/4502073572247-FigJam-for-iPad) | Floating dock; pinnable pen toolbar. [Source](https://community.miro.com/ideas/need-ability-to-pin-the-pen-toolbar-to-keep-it-open-13358) | Floating drawing palette docked to bottom-centre; collapses when not in draw mode. | Bottom-floating toolbar; collapses style picker behind a sheet. | Bottom toolbar, compact mode hides the style picker behind a toggle. [Source](https://github.com/tldraw/tldraw/issues/1709) |
| Stroke commit semantics | In-flight stroke rendered live; committed on pointer-up. (Standard.) | Same — live in-flight, commit on up. | Same. | Live in-flight; commit on up; with `isComplete` flag for final processing. [Source](https://tldraw.dev/sdk-features/draw-shape) | Same — `isComplete` toggles when pointer-up fires. |
| Shape (rect/ellipse) commit | Drag-to-create (click + drag + release). [Source](https://help.figma.com/hc/en-us/articles/360040450133-Shape-tools) | Drag-to-create. | Drag-to-create. | Drag-to-create. | Drag-to-create. [Source](https://tldraw.dev/sdk-features/geo-shape) |
| Color / brush UX | Bottom toolbar, tap the tool again to open style picker. [Source](https://help.figma.com/hc/en-us/articles/4502073572247-FigJam-for-iPad) | Pen popover on the pen tool. | Tap tool twice — second tap opens style. [Source](https://support.apple.com/en-lb/guide/ipad/ipadf825a0bd/17.0/ipados/17.0) | Side rail (desktop), bottom sheet (mobile). | Bottom toolbar + style sheet. |

**Convergent industry pattern.** Five products, three rules they all share:

1. **Tool selection arbitrates one-finger semantics.** No tool = pan. Tool = act on the tool. Excalidraw's hand tool is the same arbiter, just made explicit.
2. **Two fingers always do pan/pinch.** No product reserves two-finger for anything other than navigation. This is the most robust rule we can copy.
3. **Mid-stroke second pointer cancels the stroke.** Cancel-then-yield is the only rule that doesn't produce stray marks when the user starts a pinch one-finger-late.

## Flutter ecosystem evaluation

| Option | Bundle weight | Mobile touch quality | Tools supported | Stroke rendering | Can integrate 4096-canvas + WS sync? | Health signal |
|---|---|---|---|---|---|---|
| **perfect_freehand** (algorithm only) | tiny (~30 kB), pure Dart | n/a — no gestures | n/a — geometry only | streamline + thinning + variable width | yes — plug into our CustomPainter | active; v2.5.2 4 months ago; 6.1k weekly downloads. [pub.dev](https://pub.dev/packages/perfect_freehand) |
| **scribble** | medium (~120 kB, pulls freezed + perfect_freehand) | good (pressure-aware, eraser, undo/redo built in) | pen, eraser, color, width | uses perfect_freehand under the hood | partial — Scribble's `ScribbleNotifier` owns sketch state; we'd have to fork it or wrap it to add shape tools, text labels, WS sync, multi-user strokes. Wraps in InteractiveViewer per the changelog | moderate; v0.10.0+1, last release 2 years ago. README says "still under development". [pub.dev](https://pub.dev/packages/scribble) [github](https://github.com/timcreatedit/scribble) |
| **flutter_drawing_board** | larger (controller, board widget, image export) | claims Bezier/Catmull-Rom smoothing + palm rejection | pen, eraser, shapes, text, image | smoothing levels 0/1/2 | partial — gives us draw + zoom + pan in one widget, but rebuilding our WS sync + multi-user strokes + avatars + screen-share on top of its model would require subclassing its tools | fair; v1.0.1+2, fluttercandies publisher (active org), 4 months ago. [pub.dev](https://pub.dev/packages/flutter_drawing_board) |
| **signature** | tiny | pen-input focused (signature pad) | pen only | basic | no — single-stroke, no multi-tool, no zoom | active but wrong scope |
| **super_editor** | very heavy | n/a | rich text, not a drawing canvas | n/a | no | wrong tool for the job |
| **Hand-rolled CustomPainter + InteractiveViewer** (today) | n/a | poor — see status quo | full | raw polyline | yes — already does | maintained by us |
| **Hand-rolled CustomPainter + raw Listener-based gesture handling** | n/a | controllable — we decide every arena rule | full | up to us | yes — drop-in replacement | maintained by us |
| **fabric.js inside HtmlElementView** (web-only) | huge (~300 kB JS), web-only | excellent on web, not viable on mobile/desktop | full | excellent | no — kills cross-platform parity | not an option |

The honest read: the only Flutter package that would actually replace Echo's canvas wholesale is `flutter_drawing_board`, and that means giving up control of the gesture model, the wire format, and the multi-user state machine — none of which are bugs we want to redo. **The win is `perfect_freehand` as a pure stroke-geometry algorithm**, swapped in under the painter we already control. That's a 3-line dependency add for the smoothing problem.

## Decision

**Option B — targeted rewrite.** Date: 2026-05-28.

Three changes ship together, behind a feature flag that defaults on for new builds but is server-toggleable to roll back without redeploy.

### B.1 — Replace `InteractiveViewer` with a custom transform controller

A `LoungeCanvasViewport` widget owns:

- A `TransformationController` (Matrix4 + listeners), keeping the existing reset-pose / double-tap / keyboard-pan / fit-to-content semantics from `voice_lounge_screen.dart:160-272`.
- A root `Listener` (not `GestureDetector`) that tracks `PointerDownEvent`, `PointerMoveEvent`, `PointerUpEvent`, `PointerCancelEvent`, and `PointerSignalEvent` (mouse wheel + trackpad).
- An explicit state machine `CanvasGestureState`: `Idle | Drawing(pointerId) | Panning(pointerId) | Pinching(pointer1Id, pointer2Id) | DoubleTapPending`. Transitions are pointer-count driven, not slop-driven:
  - `Idle + pointerDown(p1)` → `Drawing(p1)` if tool selected and pointer kind is not `mouse-middle`/`mouse-right`, else `Panning(p1)`.
  - `Drawing(p1) + pointerDown(p2)` → `Pinching(p1, p2)`. **Cancel the stroke first**: emit `endStroke(canceled: true)` so the active points get discarded rather than committed.
  - `Panning(p1) + pointerDown(p2)` → `Pinching(p1, p2)`.
  - `Pinching(p1, p2) + pointerUp(p1 or p2)` → `Idle` (do NOT drop back into one-pointer pan — the user has lifted; the next gesture starts cleanly).

This kills the `kPanSlop ≈ 18 px` startup dead-zone (strokes start at the first pointer-move that exceeds the platform `touchSlop`, but the slop is now part of the explicit state machine, not an emergent arena race) and makes the "double-tap zoom while drawing" class of bug structurally impossible.

Mouse wheel + Ctrl/Cmd-modifier: handled in the same `Listener` via `PointerSignalEvent.PointerScrollEvent`. Trackpad pinch: same.

### B.2 — Split the painter into three RepaintBoundary layers

```
LoungeCanvasViewport
  └─ Transform.scale (driven by TransformationController)
      └─ SizedBox(4096×4096)
          └─ Stack
              ├─ RepaintBoundary  // background (vertex mesh, image)
              ├─ RepaintBoundary  // committed strokes + images + avatars
              │     └─ CustomPaint(StrokesPainter, repaint: strokesRevision)
              └─ RepaintBoundary  // in-flight stroke ONLY
                    └─ CustomPaint(ActiveStrokePainter, repaint: activeStrokeNotifier)
```

`activeStrokeNotifier` is a `ChangeNotifier` (single integer tick) the canvas provider bumps on every `continueStroke`. It bypasses Riverpod's `state = state.copyWith(...)` rebuild path — `_pendingStrokePoints` is held in the notifier directly, and the painter reads it via `listenable: activeStrokeNotifier`. Net effect: a `continueStroke` call repaints **only** the in-flight stroke layer (one short polyline), not the entire committed-strokes set.

The Riverpod state still gets updated on `endStroke` so other consumers (dock buttons, perf counters, tool indicators) see the new stroke when it's committed.

### B.3 — Smooth in-flight strokes with perfect_freehand

Wire format stays raw points (no API churn). Local rendering of pen + highlighter strokes calls `perfect_freehand.getStroke(points, options)` and draws the returned outline as a filled `Path`. Velocity-based simulated pressure is on by default (`simulatePressure: true`), real pressure from `PointerEvent.pressure` is used when available (Apple Pencil, S Pen, Wacom). Shapes (rect / ellipse / line / arrow) bypass smoothing — they're 2-point primitives.

This is purely client-side; remote clients receiving a `stroke_partial` get the same raw points and run the same smoothing locally. No cross-client smoothness drift.

### B.4 — Mobile toolbar collapse

Phone-portrait (`width < 600` and `orientation == portrait`):

- Bottom dock collapses to a single floating button anchored bottom-right (above iOS home-bar safe-area inset).
- Tap → expands a bottom sheet with tool/color/width/clear, matching FigJam's "tap Done to exit a tool" pattern.
- Tool stays selected after sheet dismiss; canvas takes the full viewport.

Tablet + desktop unchanged.

## Gestures matrix (canonical)

| Gesture | Touch | Mouse | Trackpad | Action | Source product |
|---|---|---|---|---|---|
| 1 pointer down, no tool | tap | left-click | tap | Select / start pan | Excalidraw hand tool, Figma |
| 1 pointer drag, no tool | drag | drag | drag | Pan | Figma, tldraw |
| 1 pointer drag, tool active | drag | drag | drag | Draw (or rubberband shape) | Figma, Miro, Freeform |
| 2 pointer drag | pinch+drag | n/a | pinch+drag | Pan + pinch-zoom | Figma, Excalidraw, tldraw |
| 2nd pointer mid-stroke | — | — | — | Cancel stroke, enter Pinching | tldraw |
| Middle-click drag | n/a | drag | n/a | Pan regardless of tool | Figma |
| Ctrl/Cmd + scroll | n/a | wheel | pinch | Zoom | Figma |
| Double-tap (no tool) | 2 taps | dbl-click | 2 taps | Zoom-toggle 1× ↔ 2× at point | Echo (kept from #1266) |
| Double-tap (tool active) | — | — | — | Suppressed | Echo (#1266) |
| Long-press | hold | n/a | n/a | (deferred — see open questions) | — |
| Right-click / 2-finger tap | 2-finger tap | r-click | 2-finger tap | Cancel draw / clear selection | input matrix v02 |
| Escape | n/a | key | n/a | Cancel draw / clear selection | input matrix v02 |
| `0` / Cmd-0 | n/a | key | n/a | Fit-to-content | Figma |

Anything not in this matrix is undefined and not yet implemented; new gestures must add a row first.

## Stroke rendering

- **Algorithm**: perfect_freehand `getStroke()` with `streamline: 0.5`, `smoothing: 0.5`, `thinning: 0.5`, `simulatePressure: true` for pen/highlighter strokes. The output is an outline polygon, drawn as a filled `Path` rather than a stroked polyline.
- **Shapes** (rect, ellipse, line): unchanged — straight geometry, 2 points.
- **Eraser**: unchanged — `BlendMode.clear` over a `saveLayer` (the existing painter does this correctly).
- **Text**: unchanged — `TextPainter` at the anchor point.
- **Layer split**:
  - L0 background (vertex mesh + uploaded image) — repaints when settings change.
  - L1 committed strokes + images + avatars + screen-share windows — repaints when `strokesRevision` ticks (end-of-stroke commits, remote events, undo/redo, clear).
  - L2 in-flight stroke — repaints when `activeStrokeNotifier` ticks (every `continueStroke`).
- **Mid-stroke setState frequency**: zero. The Riverpod state is updated on `startStroke` and `endStroke` only; all the intermediate ticks bypass it.

## Tool semantics

Pointer-down semantics per tool, in the new state machine:

| Tool | onDown | onMove | onUp |
|---|---|---|---|
| `none` | start pan (`Panning`) | translate viewport | end pan |
| `pen` | start stroke, push first point | append point, tick `activeStrokeNotifier` | commit stroke; broadcast `stroke` event |
| `highlighter` | same as pen | same as pen | commit with `kind=highlighter` |
| `eraser` | same as pen | same as pen | commit with `kind=eraser` |
| `line`, `rect`, `ellipse` | start stroke with `[first, first]` | replace second point with current pos | commit 2-point stroke |
| `text` | open text editor at point (single tap, no drag) | — | commit text label on editor confirm |
| `arrow` | same as line | same as line | commit |

`arrow` is a future addition; matches `line` semantically for now.

## Mobile UX

For `width < 600 && orientation == portrait` (390×844 reference):

- **Top bar**: 56 px — back, lounge name, members-count pill, drawing-from-device pill (if non-authority), kebab.
- **Canvas**: full remaining viewport minus 56 px top bar and 16 px bottom safe-area inset.
- **Floating tool button**: 56 px circle, bottom-right (16 px margin from edge), z-index above canvas.
- **Tap floating button**: full-width bottom sheet expands with tool grid (pen/highlighter/eraser/line/rect/ellipse/text/clear) + color row + width slider. Sheet height 280 px, dismissable by swipe-down or tap outside.
- **Active tool indicator**: floating button shows the selected tool's icon + colour; tap-to-cancel button next to it appears when a tool is selected.
- **Members panel**: hidden in portrait; accessed via members-count pill.

For everything ≥ 600 px width or landscape: existing dock layout, unchanged.

## Architecture options reconsidered

### Option A — Incremental fixes only

Keep `InteractiveViewer`. Targeted patches:
- Add `RepaintBoundary` between active and committed strokes.
- Swap raw polyline for perfect_freehand.
- Tighten the `panEnabled` toggle to also disable double-tap-zoom.
- Tune `kPanSlop`.

**Cost**: 2–3 days.
**Risk**: low.
**What ships**: smoother strokes, less mid-stroke jank, fewer arena-race bugs. The 18 px dead-zone stays. The "mobile feels bad" report mostly stays because the underlying gesture-arena model isn't the right shape for a canvas — it's the right shape for "two-finger-scroll a list".

### Option B — Targeted rewrite (chosen)

Sections B.1–B.4 above.

**Cost**: 5–8 days.
**Risk**: medium. Most risk in the state-machine transitions (B.1).
**What ships**: latency drop on phones, no dead-zone, no mid-stroke pinch fight, smooth strokes, less cramped mobile UI. The 4096-canvas world model + WS sync + multi-device authority all survive intact.

### Option C — Full rewrite onto a third-party package

Adopt `flutter_drawing_board` or fork `scribble`. Port WS sync, multi-user strokes, avatars, screen-share, encrypted-canvas handling onto their data model.

**Cost**: 15–25 days.
**Risk**: high. The data-model coupling to our WS sync, multi-device authority (`docs/voice-lounge/03-multi-device.md`), and 4096-canvas-world coord system would require subclassing/forking either package — both of which are 1–4 months stale. Plus we'd be giving up ownership of the wire format.
**What ships**: same user-visible improvements as Option B, but with a dependency we don't control. Not justified.

## Validation plan

- **Unit / widget tests** (Flutter):
  - `CanvasGestureState` transition table — every (state, event) pair has an expected next state. Tests exist for the arena handoff today (`test/widgets/lounge_drawing_canvas_test.dart`); expand them.
  - Painter layer tests — `ActiveStrokePainter` ignores committed strokes; `StrokesPainter` ignores in-flight points. Verified via `MockCanvas` recording draw calls.
- **Integration tests** (`integration_test/`):
  - Reproduce the 2-finger-mid-stroke handoff on an Android emulator and an iOS simulator. Assert the stroke is cancelled (not committed) and the final viewport scale ≠ initial scale.
  - Reproduce double-tap-while-drawing — assert no zoom toggle fires.
- **Playwright web tests** (`tests/e2e/`):
  - Smooth-stroke render visual diff (Excalidraw uses a similar approach in their visual regression suite).
- **Manual device matrix**:
  - iPhone SE (smallest viewport), Pixel 7, iPad Air, Linux desktop (mouse + trackpad), Windows desktop.
- **Perf budget** (extends `docs/voice-lounge/perf-baseline.md`):
  - Mid-stroke frame time ≤ 8 ms at 60 fps on Pixel 5 (current: ~22 ms per profiling notes in `canvas_provider.dart:_warnIfPerfDegraded`).
  - Stroke commit latency (touch up → committed stroke visible) ≤ 33 ms.
- **Deep audit script assertions** (`scripts/audit_canvas.sh`, to be added or extended):
  - Grep for `state = state.copyWith(activePoints` outside `startStroke` / `endStroke` — should match zero occurrences after B.2 lands.
  - Grep for `InteractiveViewer` in `voice_lounge_screen.dart` — should match zero occurrences after B.1 lands.
  - Grep for `Path.lineTo` in the active-stroke painter — should match zero occurrences after B.3 lands (perfect_freehand emits closed outlines, drawn via filled `Path`).

## Open questions

- **Long-press semantics on mobile.** Industry has no convergent rule (tldraw: context menu; Figma mobile: nothing; FigJam mobile: nothing). Echo has no current behaviour. Defer until first feature request (e.g. selection lasso, shape style picker on shape long-press). Pickup trigger: design ask for a mobile context menu, or testers asking for shape style editing without going through the dock.
- **Apple Pencil hover + draw-with-finger toggle.** Freeform makes this explicit ("Draw with Finger" toggle) because the Pencil is always preferred when present. Echo doesn't track input device kind at the canvas layer today. Pickup trigger: someone reports drawing with a finger when they meant to be moving the canvas, while a Pencil is also paired.
- **Lounge join/leave crash.** Out of canvas-redesign scope but blocking the user's reported experience. Should be tracked as its own bug and reproduced before this rewrite lands — fixing the canvas under a broken join path produces no perceived improvement. Pickup trigger: implementation start of B.1 — the rewrite should not be merged while users still cannot reliably enter the lounge.
- **Server geometry-validation interaction with simulated pressure.** Server validates stroke bounding boxes (PR #1269); perfect-freehand outputs vary per-device because they're velocity-thinned. Bounding box should still hold (points stay in canvas space) but worth a paired validation test. Pickup trigger: B.3 implementation, before merge.
- **Encrypted-canvas implications.** Smoothing happens client-side; raw points are still what go on the wire. No change to the `04-encrypted-canvas.md` posture. No pickup trigger required.
- **Existing committed strokes after B.3 ships.** Strokes already in the database were drawn as raw polylines. After the new smoothing renders them, they will look slightly different than they did when drawn (smoother, organic). Acceptable for the first ship; if testers report "my old drawings changed", we'd need a `rendering_version` field on the stroke and the painter would respect the version the stroke was authored under. Pickup trigger: post-ship feedback.

## Acceptance criteria

- A new gesture or transform-controller behaviour PR must update the canonical gestures matrix above first, and provide its `CanvasGestureState` transition row.
- A new tool PR must add a row to "Tool semantics".
- A PR that adds a draw operation must paint it on layer L1 (committed) or L2 (in-flight) — not both, not on L0.
- A perf regression in any of the budget metrics blocks the merge until the budget is updated with justification.
- The rewrite ships behind a feature flag (`canvas_v2_enabled`, defaults true on new builds, server-toggleable). The flag exists for two release cycles, then is removed.
