// Canvas gesture state machine — pure transition logic.
//
// Replaces the implicit, slop-driven gesture-arena race between
// InteractiveViewer + LoungeDrawingCanvas with an explicit
// pointer-count-driven state machine.
//
// See docs/voice-lounge/05-canvas-rewrite-spec.md (section B.1) and
// docs/voice-lounge/02-input-matrix.md for rationale and the canonical
// gestures matrix this implements.
//
// This file deliberately contains zero Flutter widget/painter code so the
// transitions are unit-testable without spinning up a widget tree.

/// High-level state of the canvas gesture machine.
///
/// Transitions are driven by pointer-count changes plus the
/// `isToolSelected` flag — never by slop heuristics or arena
/// arbitration. See [resolveTransition].
enum CanvasGesturePhase {
  /// No pointers down on the canvas.
  idle,

  /// Exactly one pointer down AND a draw tool is selected. The pointer's
  /// moves emit stroke-point callbacks; lifting commits the stroke.
  drawing,

  /// Exactly one pointer down AND no tool is selected. The pointer's
  /// moves translate the canvas transform.
  panning,

  /// Two pointers down. Both translate (midpoint) and scale (spread) are
  /// updated from the pair. If we arrived from [drawing], the in-flight
  /// stroke was cancelled at the transition.
  pinching,
}

/// Result of a state transition: the new phase + the side-effects the
/// widget should fire (e.g. cancel the in-flight stroke when a draw is
/// pre-empted by a second pointer).
class CanvasGestureTransition {
  final CanvasGesturePhase phase;

  /// Whether the in-flight stroke should be cancelled as part of this
  /// transition. Only true on `drawing -> pinching` (and `drawing ->
  /// idle` via cancel events, e.g. PointerCancelEvent or a tool-change
  /// while drawing).
  final bool cancelStroke;

  /// Whether a stroke should be started as part of this transition.
  /// True on `idle -> drawing`.
  final bool startStroke;

  /// Whether the active stroke should be committed (committed = not
  /// cancelled). True on `drawing -> idle` via a clean pointer-up.
  final bool commitStroke;

  const CanvasGestureTransition({
    required this.phase,
    this.cancelStroke = false,
    this.startStroke = false,
    this.commitStroke = false,
  });

  @override
  String toString() =>
      'CanvasGestureTransition($phase, cancel=$cancelStroke, '
      'start=$startStroke, commit=$commitStroke)';
}

/// Discrete events the state machine reacts to. These are produced by
/// the widget's `Listener` from raw `PointerEvent`s — see
/// `lounge_canvas_gestures.dart`.
enum CanvasGestureEvent {
  /// A pointer touched down.
  pointerDown,

  /// A pointer lifted cleanly (PointerUpEvent).
  pointerUp,

  /// A pointer was cancelled by the system (PointerCancelEvent) — treat
  /// any in-flight stroke as cancelled, not committed.
  pointerCancel,
}

/// Pure transition function. Given the current [phase], the [event] that
/// just arrived, the resulting [pointerCount] (after applying the
/// event), and whether a draw tool is currently selected, return the
/// new phase + side-effects to fire.
///
/// Transition table (per the spec):
///   idle      + down (n=1, tool)     -> drawing  (startStroke)
///   idle      + down (n=1, no-tool)  -> panning
///   drawing   + down (n=2)           -> pinching (cancelStroke)
///   panning   + down (n=2)           -> pinching
///   pinching  + down (n>=3)          -> pinching (extra pointers
///                                                ignored; we stay
///                                                pinching on the
///                                                first two)
///   drawing   + up (n=0)             -> idle     (commitStroke)
///   drawing   + cancel (n=0)         -> idle     (cancelStroke)
///   panning   + up/cancel (n=0)      -> idle
///   pinching  + up/cancel (n<=1)     -> idle     (spec: do NOT drop
///                                                back into pan; next
///                                                gesture starts clean)
///
/// Anything not listed above is a no-op (phase unchanged, no side
/// effects).
CanvasGestureTransition resolveTransition({
  required CanvasGesturePhase phase,
  required CanvasGestureEvent event,
  required int pointerCount,
  required bool isToolSelected,
}) {
  switch (event) {
    case CanvasGestureEvent.pointerDown:
      return _resolveDown(phase, pointerCount, isToolSelected);
    case CanvasGestureEvent.pointerUp:
      return _resolveLift(phase, pointerCount, cancelled: false);
    case CanvasGestureEvent.pointerCancel:
      return _resolveLift(phase, pointerCount, cancelled: true);
  }
}

CanvasGestureTransition _resolveDown(
  CanvasGesturePhase phase,
  int pointerCount,
  bool isToolSelected,
) {
  // First pointer down → either start drawing or start panning,
  // gated on whether a tool is selected.
  if (pointerCount == 1 && phase == CanvasGesturePhase.idle) {
    if (isToolSelected) {
      return const CanvasGestureTransition(
        phase: CanvasGesturePhase.drawing,
        startStroke: true,
      );
    }
    return const CanvasGestureTransition(phase: CanvasGesturePhase.panning);
  }

  // Second pointer arrives → always enter pinching. If we were
  // drawing, cancel the in-flight stroke first.
  if (pointerCount == 2 &&
      (phase == CanvasGesturePhase.drawing ||
          phase == CanvasGesturePhase.panning)) {
    return CanvasGestureTransition(
      phase: CanvasGesturePhase.pinching,
      cancelStroke: phase == CanvasGesturePhase.drawing,
    );
  }

  // Extra pointers (n >= 3) while pinching are ignored.
  return CanvasGestureTransition(phase: phase);
}

CanvasGestureTransition _resolveLift(
  CanvasGesturePhase phase,
  int pointerCount, {
  required bool cancelled,
}) {
  // Any phase + all pointers gone → idle. Drawing commits cleanly on
  // pointer-up, cancels on pointer-cancel.
  if (pointerCount == 0) {
    if (phase == CanvasGesturePhase.drawing) {
      return CanvasGestureTransition(
        phase: CanvasGesturePhase.idle,
        commitStroke: !cancelled,
        cancelStroke: cancelled,
      );
    }
    return const CanvasGestureTransition(phase: CanvasGesturePhase.idle);
  }

  // Pinching + one pointer remains → drop to idle per the spec
  // ("ignore the lone surviving pointer until the next pointer-down").
  if (phase == CanvasGesturePhase.pinching && pointerCount == 1) {
    return const CanvasGestureTransition(phase: CanvasGesturePhase.idle);
  }

  // Otherwise no-op.
  return CanvasGestureTransition(phase: phase);
}
