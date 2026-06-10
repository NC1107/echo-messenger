# Voice-Lounge Canvas — Architecture Assessment (2026-06-10)

> Audit triggered by the maintainer's read: "the goal of the lounge is unclear, the
> aesthetics need work, it should be a simple Figma/Miro/draw.io canvas, and the
> current JSON/image model will hit limits + perf + consistency issues, with the
> canvas-size problem unresolved." Four parallel read-only audits (data model,
> rendering, sync, product/UX). **The instinct is correct on every count.** This
> doc is the synthesis + recommended direction. It supersedes nothing in
> `05-canvas-rewrite-spec.md` (that rewrite shipped and is good — see below); it
> addresses the layer *beneath* it.

## TL;DR

The **gesture + rendering rewrite (`05-*`) shipped and is solid**: explicit gesture
state machine, 3-layer `RepaintBoundary`, `perfect_freehand` smoothing, draggable/
resizable canvas items. That is **not** where the problems are.

The Figma/Miro/draw.io bar is blocked by four things *below* the rendering layer:

1. **Data model** — a board is two flat append-only JSONB arrays (`drawing_data`,
   `images_data`) with 2000-item caps. No object graph. Dead-end for select/move/
   resize/group/undo and for scale.
2. **Sync model** — per-event relay with **no sequence numbers, ordering, or CRDT**.
   Clients can and do diverge.
3. **Canvas size** — a **fixed 6000×6000** surface, not infinite. This *is* the
   unresolved "size" problem.
4. **Product identity** — one surface conflates three things: voice **presence**
   (draggable avatar pucks), a **whiteboard** (strokes/shapes/text), and a
   **screen-share window manager**. Figma/Miro/draw.io are one thing: an object
   canvas.

None of these are reachable by incremental patching of the current model. Hitting
the bar is a *foundational* change, and it's worth deciding deliberately rather than
drifting.

## What's actually good (don't rebuild these)

- `lounge_canvas_gestures.dart` + `canvas_gesture_state.dart`: explicit pointer-count
  state machine (idle/drawing/panning/pinching), no slop dead-zone, no arena races.
- `lounge_canvas_strokes.dart`: 3-layer paint (bg / committed / in-flight), per-stroke
  outline memoization, `perfect_freehand` smoothing, eraser via `saveLayer`+`dstOut`.
- `draggable_canvas_item.dart`: shared drag/resize frame (images + screen-share).
- `canvas_grid_background.dart`: adaptive 1-2-5×10ⁿ ruler grid — genuinely Figma-grade.

## The four ceilings

### 1. Data model (`db/canvas.rs`, `canvas_models.dart`) — dead-end
- One row per channel: `drawing_data JSONB` (array of stroke objects, each a raw point
  list) + `images_data JSONB`. Append-only; `update_image` rebuilds the **whole**
  `images_data` array via `jsonb_agg` (write-amplification — #1339 reduced it to
  commit-only this session, but it's still O(N) per commit).
- Hard caps: `MAX_STROKES = MAX_IMAGES = 2000`; over-cap content is silently rejected.
- Join load (`get_canvas`) returns the entire board in one payload, **unpaginated**
  (#1340). At cap, that's multi-MB JSON on every join.
- **Missing for Figma/Miro**: object identity beyond append, z-order/layers, affine
  transforms (rotation), grouping, multi-select, **undo/redo**, connectors/arrows,
  text-in-shape, hit-test index. None are addable inside the two-blob model.
- **Verdict**: replace with per-object storage — `canvas_objects(channel_id, object_id,
  type, z, transform, props JSONB, seq)` — which simultaneously removes the cap, kills
  the full-array rewrite (point-update one row), and is the substrate for everything
  above.

### 2. Sync model (`ws/events/canvas.rs`, `canvas_provider.dart`) — diverges
- Per-event relay-and-persist. **No sequence numbers, vector clocks, OT, or CRDT.**
  Clients apply events in *reception* order, which differs per client.
- The "authority/leader" is only an in-memory single-writer lock per user's devices
  (1s grace window) — not ordering or conflict resolution.
- Concrete divergence paths (cited in the sync audit): concurrent image-move race
  (relay order ≠ persist order), stroke-partial reordering, clear-racing-an-in-flight-
  stroke "resurrection", late-joiner mid-fetch double-apply, multi-device authority
  skew, lost ephemeral events on reconnect.
- **Smallest real fix** (≈2–4 wk, no CRDT lib): **server-assigned `seq`** on every
  persisted op; clients order by `seq`; late-joiners fetch `last_seq` and replay from
  there. Deterministic convergence; LWW-by-seq for conflicts.

### 3. Canvas size — fixed, not infinite
- `kCanvasWidth = kCanvasHeight = 6000` (history: 100k → 4096 → 6000). Gestures clamp
  to keep ≥15% on-screen; zoom 0.2×–5.0×. Content past the edge is clamped/rejected.
- **This is the "unresolved size" complaint.** Infinite (Miro-style) needs viewport-
  relative/large-precision coords + **viewport culling or tiling** so paint is
  O(visible) not O(total strokes) — currently the committed layer paints every stroke
  every repaint (perf cliff ~500–1000 strokes with multiple active drawers).

### 4. Product identity — three apps on one surface
- Avatars (draggable presence pucks) + whiteboard content + screen-share windows all
  live in the same coordinate space and authority model. That's the muddle behind
  "what is the lounge for." Figma/Miro/draw.io don't put call-presence *on the canvas*.
- **Recommendation**: make the canvas a pure **object whiteboard**; move presence to a
  roster/overlay (or an optional, visually-distinct layer that isn't a canvas object).

## Recommended direction (phased)

**Phase 0 — Product decision: DECIDED 2026-06-10 → whiteboard-first.** The lounge is a
collaborative Figma/Miro/draw.io-style **object canvas** that happens to have voice.
Consequence: **presence (avatars) is demoted from a canvas object to a roster/overlay**
— it must not share the canvas coordinate space or authority model. Chrome is
canvas-first (calm, minimal; the board is the hero). This commitment is what makes
Phases 1–3 worth doing.

**Phase 1 — Ordered sync (`seq`).** Highest value-per-effort: fixes the *consistency*
complaint without a rewrite. ~2–4 wk. Server-side, mostly additive.

**Phase 2 — Object model.** `canvas_objects` table + object-delta wire protocol.
Removes the 2000 cap, kills the full-array rewrite, and unlocks select/move/resize/
group/undo/redo. The big one; enables real Figma/Miro features. Builds on Phase 1's
`seq`.

**Phase 3 — Infinite canvas + culling.** Viewport-relative coords + tiling/culling so
the surface isn't a 6000 box and paint scales. Depends on Phase 2 (objects are what you
cull/tile).

**Phase 4 — Whiteboard affordances + polish.** Selection UI, multi-select, connectors,
text editing, snapping, undo/redo UI; premium chrome; mobile dock collapse.

Phases 1–3 are foundational and sequential; each is independently shippable and leaves
the lounge working. Phase 4 is incremental once 1–3 land.

## Known-good vs known-broken (quick map)

| Area | State |
|---|---|
| Gesture state machine / pan-zoom-draw | ✅ shipped, solid |
| Stroke smoothing (perfect_freehand) | ✅ shipped |
| 3-layer repaint isolation | ✅ shipped |
| Draggable/resizable images + screenshare | ✅ shipped |
| Data model (flat JSONB, 2000 cap) | ❌ dead-end for the target |
| Sync ordering / convergence | ❌ no seq/CRDT — diverges |
| Canvas size (fixed 6000) | ❌ not infinite; paints O(total) |
| Object select/move/resize/group/undo | ❌ absent |
| Product identity (presence vs canvas) | ⚠️ conflated |

## Deferred items this rolls up
- #1339 image write-amplification (commit-gated this session; full-array rewrite remains
  on commit → solved by Phase 2 per-object rows).
- #1340 `get_canvas` pagination (solved by Phase 2 + `seq` ranged fetch).
