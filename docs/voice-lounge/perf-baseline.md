# Voice-Lounge Canvas Performance Baseline

Phase 5 / PR F of `canvas_redesign.md` v2.

This document captures the measurement methodology, budget targets, and first
measured numbers for the voice-lounge canvas.  Future PRs that touch
`canvas_provider.dart` or `voice_canvas.dart` must not regress any metric
below its threshold (budget × 1.20).

---

## Measurement methodology

### Scenario

| Dimension | Value |
|-----------|-------|
| Participants | 8 (1 local + 7 remote) |
| Reference device | Pixel 5 or equivalent (~6 GB RAM, Android 13) |
| Draw pattern | Continuous freehand pen at ~30 fps for 60 s |
| Network | LAN or localhost loopback (removes server RTT as variable) |
| Client build | Flutter release (`--release`) with CanvasKit |

### Instrumented paths

1. **Paint duration** — `_CanvasPainter.paint()` in `voice_canvas.dart`.
   A `Stopwatch` wraps the entire `paint()` body.  Duration is recorded via
   `CanvasPerf.recordPaintMs()` after each call.

2. **Stroke-point accumulation** — `continueStroke()` in `canvas_provider.dart`.
   A `Stopwatch` wraps the state-mutation and throttle-setup work.
   Duration recorded via `CanvasPerf.recordPaintMs()` so both hot paths
   feed the same rolling window.

3. **WS send rate** — `_flushStrokePoints()` in `canvas_provider.dart`.
   Each outbound `stroke_partial` frame calls `CanvasPerf.recordSendEvent()`.
   The per-second bucket counter tracks bursts.

### Reading a snapshot

```
CanvasPerf.snapshot()
// → { paint_p50_ms, paint_p99_ms, send_events_per_sec_avg, send_events_per_sec_p99 }
```

A debug-log breadcrumb is emitted every 30 s at `LogLevel.fine` from
`canvas_provider.dart` while a lounge is attached:

```
[canvas-perf] paint p50=Xms p99=Yms send/s avg=Z p99=W
```

Snapshots are also visible in the in-app debug log viewer (Settings → About →
Debug Log) for field triage.

### Triggering the measurement yourself

1. Run the release build with two browser tabs (or two desktop instances) on
   the same lounge channel.
2. Use the freehand pen tool continuously for at least 60 s while watching
   the debug log for the `[canvas-perf]` line.
3. Record the p99 values from the snapshot after 60 s.

---

## Budget targets

These are hard commitments.  A regression is defined as any value exceeding
budget × 1.20 (i.e. a 20 % regression tolerance).

| Metric | Budget | Regression threshold |
|--------|--------|----------------------|
| `paint_p99_ms` at 8 participants (Pixel 5) | ≤ 16 ms | > 19.2 ms |
| `send_events_per_sec_p99` during active draw | ≤ 50 /s/participant | > 60 /s |
| First frame after join (canvas mounts → first paint) | < 800 ms | > 960 ms |

**Rationale for paint_p99 = 16 ms:** 16 ms is the frame budget for 60 fps.
A stroke-paint p99 that exceeds one frame means the user visibly experiences
jank on at least 1 % of frames during continuous drawing.

**Rationale for send rate = 50 /s/participant:** The 30 Hz throttle timer in
`_flushStrokePoints` fires at most 30 times/s.  At 8 participants all drawing
simultaneously the server receives up to 240 events/s total.  Per-participant
50 /s gives 60 % headroom above the timer frequency to absorb brief
pointer-move bursts without overwhelming the WS hub.

**Rationale for first-frame < 800 ms:** The canvas snapshot REST fetch is the
dominant latency source on join.  800 ms matches the P95 REST round-trip
measured on the production server in May 2026 (US-East region, empty canvas).

---

## Measured numbers

TBD — first measurement deferred to operator on first real lounge load.

The instrumentation is in place as of this commit.  To take the first reading:

1. Build with `--release` and join a lounge with 7+ additional participants.
2. Draw continuously for 60 s.
3. Read the `[canvas-perf]` line from the debug log.
4. Update the table below and commit.

| Date | Device | Participants | paint_p50_ms | paint_p99_ms | send/s avg | send/s p99 |
|------|--------|--------------|-------------|-------------|------------|------------|
| TBD  | TBD    | TBD          | TBD         | TBD         | TBD        | TBD        |

---

## Follow-up CI gate

Automated regression gating against these budgets is out of scope for PR F
(per `canvas_redesign.md` Phase 5 non-goals).  A follow-up ticket should wire
`CanvasPerf.snapshot()` into a Flutter benchmark target and fail the build when
p99 regresses by > 20 %.

See `canvas_redesign.md` Phase 5 for the broader Phase F scope.
