// Lounge canvas gesture + transform widget.
//
// Replaces the InteractiveViewer + LoungeDrawingCanvas overlay combo
// with a single Listener-driven widget that owns:
//
//   - The canvas-world transform (Matrix4: scale + translate),
//   - Raw PointerEvent capture (no GestureDetector — we never want to
//     fight the gesture arena),
//   - The CanvasGesturePhase state machine (see canvas_gesture_state.dart),
//   - Double-tap-to-zoom, gated on tool != none per the input-matrix
//     contract (docs/voice-lounge/02-input-matrix.md and #1266).
//
// See docs/voice-lounge/05-canvas-rewrite-spec.md (sections B.1 + the
// canonical gestures matrix) for the full design rationale.
//
// Intentionally NOT integrated with voice_lounge_screen.dart in this
// PR — the parent agent wires it in after the Round-2 strokes layer
// lands. The widget compiles standalone.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'canvas_gesture_state.dart';

/// Double-tap detection window. Matches Material `kDoubleTapTimeout`
/// (300 ms) but trimmed slightly for snappier canvas feel.
const Duration _kDoubleTapTimeout = Duration(milliseconds: 250);

/// Target zoom level when double-tapping into the canvas. Matches the
/// behaviour preserved from `voice_lounge_screen.dart`'s
/// `_toggleDoubleTapZoom`.
const double _kDoubleTapZoomScale = 2.0;

/// Pointer-count + transform aware gesture surface for the voice-lounge
/// canvas.
///
/// Mount this around the canvas content; pass `isToolSelected = true`
/// when the user has picked a draw tool from the dock. The widget will:
///
///   - Emit `onStrokeStart` / `onStrokeMove` / `onStrokeEnd` on
///     single-pointer drags when a tool is selected.
///   - Emit `onStrokeCancel` when a second pointer pre-empts an
///     in-flight stroke.
///   - Pan the transform when no tool is selected.
///   - Pinch-zoom + pan when two pointers are down.
///   - Double-tap-zoom to 2x at the tap point when no tool is
///     selected (and back to 1x on a second double-tap).
///
/// `child` is rendered inside the transformed surface — Round-2 mounts
/// its strokes painter here.
class LoungeCanvasGestures extends StatefulWidget {
  /// Content rendered inside the transformed surface.
  final Widget child;

  /// Whether a draw tool is currently selected. Drives the
  /// pan-vs-draw branch of the state machine and gates double-tap zoom.
  final bool isToolSelected;

  /// Called with the canvas-space point when a stroke begins.
  final void Function(Offset canvasPoint) onStrokeStart;

  /// Called with the canvas-space point on every move sample.
  final void Function(Offset canvasPoint) onStrokeMove;

  /// Called when a stroke ends cleanly (single pointer lifted).
  final void Function() onStrokeEnd;

  /// Called when an in-flight stroke is pre-empted — second pointer
  /// down (transition drawing → pinching) or PointerCancelEvent.
  final void Function() onStrokeCancel;

  /// Called whenever the transform changes (pan / pinch / double-tap).
  /// Wired by the parent for reset-view enablement, perf logs, and
  /// last-pose persistence.
  final void Function(Matrix4 transform)? onTransformChanged;

  /// Initial transform — typically the lounge's `_centeredPose(...)`
  /// auto-fit-to-content matrix.
  final Matrix4 initialTransform;

  /// Minimum scale. Clamped against pinch + double-tap zoom.
  final double minScale;

  /// Maximum scale. Clamped against pinch + double-tap zoom.
  final double maxScale;

  const LoungeCanvasGestures({
    super.key,
    required this.child,
    required this.isToolSelected,
    required this.onStrokeStart,
    required this.onStrokeMove,
    required this.onStrokeEnd,
    required this.onStrokeCancel,
    required this.initialTransform,
    this.onTransformChanged,
    this.minScale = 0.2,
    this.maxScale = 5.0,
  });

  @override
  State<LoungeCanvasGestures> createState() => LoungeCanvasGesturesState();
}

/// Per-pointer tracking record. Stored so pinch math has both pointers'
/// last positions without re-walking PointerEvent history.
class _PointerSample {
  Offset position;
  _PointerSample(this.position);
}

/// Public for `@visibleForTesting` access to the gesture phase + the
/// transform. Tests assert on `phase` after dispatching synthetic
/// PointerEvents.
class LoungeCanvasGesturesState extends State<LoungeCanvasGestures> {
  /// Current transform. Internally mutable; observers receive the new
  /// matrix via [LoungeCanvasGestures.onTransformChanged].
  late Matrix4 _transform;

  /// Active pointers, keyed by `PointerEvent.pointer` id, in the order
  /// they arrived. The first two define the pinch pair when phase ==
  /// pinching.
  final List<int> _pointerOrder = <int>[];
  final Map<int, _PointerSample> _pointers = <int, _PointerSample>{};

  /// Cached state-machine phase.
  CanvasGesturePhase _phase = CanvasGesturePhase.idle;

  /// Public listenable view of the gesture phase, used by the lounge's
  /// optional on-canvas debug overlay. Re-fires whenever the phase
  /// transitions.
  final ValueNotifier<CanvasGesturePhase> _phaseListenable =
      ValueNotifier<CanvasGesturePhase>(CanvasGesturePhase.idle);

  /// Public read-only access to the live gesture phase. Safe to read
  /// from a ValueListenableBuilder subscription.
  ValueListenable<CanvasGesturePhase> get phaseListenable => _phaseListenable;

  /// Live pointer count + current transform, surfaced for the debug
  /// overlay (user feedback 2026-05-29 on canvas rewrite live test,
  /// bug 5).
  int get debugPointerCount => _pointers.length;
  Matrix4 get debugTransform => Matrix4.copy(_transform);

  /// Origin spread + midpoint when entering pinching, for relative
  /// scale + pan math.
  double? _pinchStartSpread;
  Offset? _pinchStartMidpoint;
  Matrix4? _pinchStartTransform;

  /// For panning: last seen pointer position, in viewport pixels.
  Offset? _panLastPosition;

  /// Most-recent pointer-down position + time, for double-tap detection.
  Offset? _lastTapPosition;
  DateTime? _lastTapAt;

  /// Whether a stroke is currently in flight (between onStrokeStart
  /// and either onStrokeEnd or onStrokeCancel). Tracked separately
  /// from `_phase` so the widget can correctly fire `commitStroke` on
  /// PointerUpEvent without re-reading the state machine output.
  bool _strokeActive = false;

  @override
  void initState() {
    super.initState();
    _transform = Matrix4.copy(widget.initialTransform);
  }

  @override
  void dispose() {
    _phaseListenable.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LoungeCanvasGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the tool selection toggles mid-stroke, cancel the stroke —
    // the input-matrix contract (rule 4) says tool switching is
    // destructive. We don't auto-restart drawing because that would
    // require synthesising a fresh PointerDownEvent.
    if (oldWidget.isToolSelected && !widget.isToolSelected && _strokeActive) {
      _strokeActive = false;
      widget.onStrokeCancel();
    }
  }

  // --- @visibleForTesting accessors ------------------------------------

  @visibleForTesting
  CanvasGesturePhase get phase => _phase;

  @visibleForTesting
  Matrix4 get transform => Matrix4.copy(_transform);

  @visibleForTesting
  int get pointerCount => _pointers.length;

  // --- Imperative controller surface -----------------------------------

  /// Replace the current viewport transform with [next]. Used by the
  /// lounge-screen's reset-view affordance to push a fresh auto-fit
  /// pose without rebuilding the entire subtree. Cancels any in-flight
  /// stroke first so the reset can't strand committed-but-uncommitted
  /// points under the new transform.
  ///
  /// Also invalidates any cached pinch baseline + pan anchor so the
  /// NEXT pinch / pan after a reset re-seeds against the freshly-pushed
  /// transform — otherwise a pinch-zoom-out following the centre button
  /// snaps to a stale anchor.
  ///
  /// User feedback 2026-05-29 on canvas rewrite live test, bug 4.
  void resetToTransform(Matrix4 next) {
    if (_strokeActive) {
      _strokeActive = false;
      widget.onStrokeCancel();
    }
    _transform = Matrix4.copy(next);
    _pinchStartSpread = null;
    _pinchStartMidpoint = null;
    _pinchStartTransform = null;
    _panLastPosition = null;
    _lastTapPosition = null;
    _lastTapAt = null;
    _emitTransform();
    if (mounted) setState(() {});
  }

  // --- Listener handlers -----------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = _PointerSample(event.localPosition);
    _pointerOrder.add(event.pointer);

    // Double-tap detection runs BEFORE the state-machine transition so
    // the second tap doesn't get consumed as a "start a stroke / start
    // a pan" event. Spec: only when tool == none.
    if (!widget.isToolSelected && _isDoubleTap(event)) {
      _handleDoubleTap(event.localPosition);
      _lastTapPosition = null;
      _lastTapAt = null;
      // Don't actually start a pan from this tap. Drop the pointer
      // from tracking so we won't try to pan/cancel on its release.
      _pointers.remove(event.pointer);
      _pointerOrder.remove(event.pointer);
      return;
    }
    _lastTapPosition = event.localPosition;
    _lastTapAt = DateTime.now();

    final transition = resolveTransition(
      phase: _phase,
      event: CanvasGestureEvent.pointerDown,
      pointerCount: _pointers.length,
      isToolSelected: widget.isToolSelected,
    );
    _applyTransition(transition, event.localPosition);
  }

  void _onPointerMove(PointerMoveEvent event) {
    final sample = _pointers[event.pointer];
    if (sample == null) return;
    sample.position = event.localPosition;

    switch (_phase) {
      case CanvasGesturePhase.drawing:
        if (_strokeActive) {
          widget.onStrokeMove(_toCanvasPoint(event.localPosition));
        }
        break;
      case CanvasGesturePhase.panning:
        _applyPanDelta(event.localPosition);
        break;
      case CanvasGesturePhase.pinching:
        _applyPinch();
        break;
      case CanvasGesturePhase.idle:
        break;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _handleLift(event.pointer, cancelled: false);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _handleLift(event.pointer, cancelled: true);
  }

  void _handleLift(int pointerId, {required bool cancelled}) {
    if (!_pointers.containsKey(pointerId)) return;
    _pointers.remove(pointerId);
    _pointerOrder.remove(pointerId);
    final transition = resolveTransition(
      phase: _phase,
      event: cancelled
          ? CanvasGestureEvent.pointerCancel
          : CanvasGestureEvent.pointerUp,
      pointerCount: _pointers.length,
      isToolSelected: widget.isToolSelected,
    );
    _applyTransition(transition, null);
  }

  // --- Transition application ------------------------------------------

  void _applyTransition(CanvasGestureTransition t, Offset? entryPoint) {
    // Side effects first (stroke callbacks reference the OLD phase).
    if (t.cancelStroke && _strokeActive) {
      _strokeActive = false;
      widget.onStrokeCancel();
    }
    if (t.commitStroke && _strokeActive) {
      _strokeActive = false;
      widget.onStrokeEnd();
    }

    final wasPhase = _phase;
    _phase = t.phase;
    if (wasPhase != _phase) _phaseListenable.value = _phase;

    // Phase-entry bookkeeping.
    if (_phase == CanvasGesturePhase.drawing &&
        t.startStroke &&
        entryPoint != null) {
      _strokeActive = true;
      widget.onStrokeStart(_toCanvasPoint(entryPoint));
    }
    if (_phase == CanvasGesturePhase.panning && entryPoint != null) {
      _panLastPosition = entryPoint;
    }
    if (_phase == CanvasGesturePhase.pinching) {
      _seedPinch();
    }

    // Phase-exit cleanup.
    if (wasPhase == CanvasGesturePhase.pinching &&
        _phase != CanvasGesturePhase.pinching) {
      _pinchStartSpread = null;
      _pinchStartMidpoint = null;
      _pinchStartTransform = null;
    }
    if (wasPhase == CanvasGesturePhase.panning &&
        _phase != CanvasGesturePhase.panning) {
      _panLastPosition = null;
    }
  }

  // --- Pan / pinch / zoom math -----------------------------------------

  void _applyPanDelta(Offset current) {
    final last = _panLastPosition;
    if (last == null) {
      _panLastPosition = current;
      return;
    }
    final delta = current - last;
    _panLastPosition = current;
    final t = _transform.getTranslation();
    _transform = Matrix4.copy(_transform)
      ..setTranslationRaw(t.x + delta.dx, t.y + delta.dy, t.z);
    _emitTransform();
  }

  void _seedPinch() {
    if (_pointerOrder.length < 2) return;
    final p1 = _pointers[_pointerOrder[0]]?.position;
    final p2 = _pointers[_pointerOrder[1]]?.position;
    if (p1 == null || p2 == null) return;
    _pinchStartSpread = (p1 - p2).distance;
    _pinchStartMidpoint = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    _pinchStartTransform = Matrix4.copy(_transform);
  }

  void _applyPinch() {
    if (_pointerOrder.length < 2) return;
    final startSpread = _pinchStartSpread;
    final startMidpoint = _pinchStartMidpoint;
    final startTransform = _pinchStartTransform;
    if (startSpread == null ||
        startSpread == 0 ||
        startMidpoint == null ||
        startTransform == null) {
      return;
    }
    final p1 = _pointers[_pointerOrder[0]]?.position;
    final p2 = _pointers[_pointerOrder[1]]?.position;
    if (p1 == null || p2 == null) return;

    final currentSpread = (p1 - p2).distance;
    final currentMidpoint = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final ratio = currentSpread / startSpread;

    final startScale = startTransform.getMaxScaleOnAxis();
    final targetScale = (startScale * ratio).clamp(
      widget.minScale,
      widget.maxScale,
    );
    final clampedRatio = targetScale / startScale;

    // Build new transform: scale-around-startMidpoint, then offset by
    // the pinch-pan delta (currentMidpoint - startMidpoint).
    final inverse = Matrix4.copy(startTransform)..invert();
    final canvasPoint = MatrixUtils.transformPoint(inverse, startMidpoint);
    final pannedMidpoint = currentMidpoint;
    _transform = Matrix4.identity()
      ..scaleByDouble(targetScale, targetScale, targetScale, 1)
      ..setTranslationRaw(
        pannedMidpoint.dx - canvasPoint.dx * targetScale,
        pannedMidpoint.dy - canvasPoint.dy * targetScale,
        0,
      );
    // The intermediate `clampedRatio` is referenced so the static
    // analyzer doesn't drop the clamp branch — and it documents intent.
    assert(clampedRatio > 0);
    _emitTransform();
  }

  void _emitTransform() {
    widget.onTransformChanged?.call(Matrix4.copy(_transform));
  }

  Offset _toCanvasPoint(Offset viewportPoint) {
    final inverse = Matrix4.copy(_transform)..invert();
    return MatrixUtils.transformPoint(inverse, viewportPoint);
  }

  // --- Double-tap zoom -------------------------------------------------

  bool _isDoubleTap(PointerDownEvent event) {
    final lastAt = _lastTapAt;
    final lastPos = _lastTapPosition;
    if (lastAt == null || lastPos == null) return false;
    if (DateTime.now().difference(lastAt) > _kDoubleTapTimeout) return false;
    // Reject if the tap drifted far enough to be a separate gesture.
    return (event.localPosition - lastPos).distance < 24.0;
  }

  void _handleDoubleTap(Offset tapPoint) {
    final currentScale = _transform.getMaxScaleOnAxis();
    final atZoomedIn = (currentScale - _kDoubleTapZoomScale).abs() < 0.01;
    final targetScale = atZoomedIn ? 1.0 : _kDoubleTapZoomScale;
    final clampedTarget = targetScale.clamp(widget.minScale, widget.maxScale);
    _transform = _zoomAround(_transform, tapPoint, clampedTarget);
    _emitTransform();
    if (mounted) setState(() {});
  }

  // --- build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // The Listener must claim the full visible viewport — not just the
    // bounds of the Transform'd child — otherwise pointer-down outside
    // the (possibly down-scaled) canvas surface never reaches the
    // gesture machine. SizedBox.expand inflates the Listener's render
    // box to the parent's constraints; `behavior: opaque` then
    // guarantees every pixel in that box is a hit-test target.
    //
    // ClipRect keeps the 100 000-px canvas child from painting outside
    // the lounge body when zoomed in or panned.
    return ClipRect(
      child: SizedBox.expand(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: Transform(transform: _transform, child: widget.child),
        ),
      ),
    );
  }
}

/// Returns a new transform that scales [current] to [targetScale] while
/// keeping the canvas-space point currently under [tapPoint] anchored to
/// the same viewport pixel.
///
/// Same math as the existing top-level `zoomAroundPoint` in
/// `voice_lounge_screen.dart`. Kept local here so the widget compiles
/// standalone — the parent agent will deduplicate at integration time.
@visibleForTesting
Matrix4 zoomAround(Matrix4 current, Offset tapPoint, double targetScale) =>
    _zoomAround(current, tapPoint, targetScale);

Matrix4 _zoomAround(Matrix4 current, Offset tapPoint, double targetScale) {
  final inverse = Matrix4.copy(current)..invert();
  final canvasPoint = MatrixUtils.transformPoint(inverse, tapPoint);
  return Matrix4.identity()
    ..scaleByDouble(targetScale, targetScale, targetScale, 1)
    ..setTranslationRaw(
      tapPoint.dx - canvasPoint.dx * targetScale,
      tapPoint.dy - canvasPoint.dy * targetScale,
      0,
    );
}
