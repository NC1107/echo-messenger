// Tests for the canvas gesture state machine + the widget that wires it
// up to raw PointerEvents. See docs/voice-lounge/05-canvas-rewrite-spec.md
// (section B.1) and docs/voice-lounge/02-input-matrix.md.

import 'package:echo_app/src/widgets/voice_lounge/canvas_gesture_state.dart';
import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_gestures.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder {
  final List<Offset> strokeStarts = <Offset>[];
  final List<Offset> strokeMoves = <Offset>[];
  int strokeEnds = 0;
  int strokeCancels = 0;
  final List<Matrix4> transforms = <Matrix4>[];
}

LoungeCanvasGestures _harness({
  required _Recorder rec,
  required bool isToolSelected,
  Matrix4? initial,
  double minScale = 0.2,
  double maxScale = 5.0,
  Key? key,
}) {
  return LoungeCanvasGestures(
    key: key,
    isToolSelected: isToolSelected,
    initialTransform: initial ?? Matrix4.identity(),
    minScale: minScale,
    maxScale: maxScale,
    onStrokeStart: rec.strokeStarts.add,
    onStrokeMove: rec.strokeMoves.add,
    onStrokeEnd: () => rec.strokeEnds++,
    onStrokeCancel: () => rec.strokeCancels++,
    onTransformChanged: (m) => rec.transforms.add(Matrix4.copy(m)),
    child: const SizedBox(width: 800, height: 600),
  );
}

LoungeCanvasGesturesState _stateOf(WidgetTester tester, Key key) =>
    tester.state<LoungeCanvasGesturesState>(find.byKey(key));

Future<void> _pointerDown(
  WidgetTester tester,
  TestGesture? Function() _, {
  required Offset at,
  required int pointer,
}) async {
  // Use HitTest dispatch directly so we can deterministically drive the
  // Listener with synthetic PointerEvents (pointer ids matter).
  final hitTest = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hitTest, at, tester.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerDownEvent(pointer: pointer, position: at),
    hitTest,
  );
  await tester.pump();
}

Future<void> _pointerMove(
  WidgetTester tester, {
  required Offset to,
  required int pointer,
}) async {
  final hitTest = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hitTest, to, tester.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerMoveEvent(pointer: pointer, position: to),
    hitTest,
  );
  await tester.pump();
}

Future<void> _pointerUp(
  WidgetTester tester, {
  required Offset at,
  required int pointer,
}) async {
  final hitTest = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hitTest, at, tester.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerUpEvent(pointer: pointer, position: at),
    hitTest,
  );
  await tester.pump();
}

Future<void> _pointerCancel(
  WidgetTester tester, {
  required Offset at,
  required int pointer,
}) async {
  final hitTest = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hitTest, at, tester.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerCancelEvent(pointer: pointer, position: at),
    hitTest,
  );
  await tester.pump();
}

void main() {
  group('resolveTransition (pure state machine)', () {
    test('idle + down with tool → drawing + startStroke', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.idle,
        event: CanvasGestureEvent.pointerDown,
        pointerCount: 1,
        isToolSelected: true,
      );
      expect(t.phase, CanvasGesturePhase.drawing);
      expect(t.startStroke, isTrue);
      expect(t.cancelStroke, isFalse);
    });

    test('idle + down with no tool → panning', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.idle,
        event: CanvasGestureEvent.pointerDown,
        pointerCount: 1,
        isToolSelected: false,
      );
      expect(t.phase, CanvasGesturePhase.panning);
      expect(t.startStroke, isFalse);
    });

    test('drawing + 2nd pointer → pinching + cancelStroke', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.drawing,
        event: CanvasGestureEvent.pointerDown,
        pointerCount: 2,
        isToolSelected: true,
      );
      expect(t.phase, CanvasGesturePhase.pinching);
      expect(t.cancelStroke, isTrue);
    });

    test('panning + 2nd pointer → pinching (no cancel)', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.panning,
        event: CanvasGestureEvent.pointerDown,
        pointerCount: 2,
        isToolSelected: false,
      );
      expect(t.phase, CanvasGesturePhase.pinching);
      expect(t.cancelStroke, isFalse);
    });

    test('drawing + clean up → idle + commitStroke', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.drawing,
        event: CanvasGestureEvent.pointerUp,
        pointerCount: 0,
        isToolSelected: true,
      );
      expect(t.phase, CanvasGesturePhase.idle);
      expect(t.commitStroke, isTrue);
      expect(t.cancelStroke, isFalse);
    });

    test('drawing + cancel → idle + cancelStroke (no commit)', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.drawing,
        event: CanvasGestureEvent.pointerCancel,
        pointerCount: 0,
        isToolSelected: true,
      );
      expect(t.phase, CanvasGesturePhase.idle);
      expect(t.cancelStroke, isTrue);
      expect(t.commitStroke, isFalse);
    });

    test('pinching + one pointer lifts → idle (no fall-back to pan)', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.pinching,
        event: CanvasGestureEvent.pointerUp,
        pointerCount: 1,
        isToolSelected: false,
      );
      expect(t.phase, CanvasGesturePhase.idle);
    });

    test('panning + clean up → idle (no stroke side-effects)', () {
      final t = resolveTransition(
        phase: CanvasGesturePhase.panning,
        event: CanvasGestureEvent.pointerUp,
        pointerCount: 0,
        isToolSelected: false,
      );
      expect(t.phase, CanvasGesturePhase.idle);
      expect(t.commitStroke, isFalse);
      expect(t.cancelStroke, isFalse);
    });
  });

  group('LoungeCanvasGestures widget', () {
    testWidgets('starts drawing on 1st pointer when tool is selected', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: true, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(100, 100),
        pointer: 1,
      );
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.drawing);
      expect(rec.strokeStarts, hasLength(1));

      await _pointerMove(tester, to: const Offset(120, 130), pointer: 1);
      expect(rec.strokeMoves, hasLength(1));

      await _pointerUp(tester, at: const Offset(120, 130), pointer: 1);
      expect(rec.strokeEnds, 1);
      expect(rec.strokeCancels, 0);
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.idle);
    });

    testWidgets('panning when no tool is selected', (tester) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(50, 50),
        pointer: 1,
      );
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.panning);
      expect(rec.strokeStarts, isEmpty);

      await _pointerMove(tester, to: const Offset(80, 70), pointer: 1);
      expect(rec.transforms, isNotEmpty);
      final last = rec.transforms.last;
      // Translation should be roughly (30, 20).
      expect(last.getTranslation().x, closeTo(30, 0.5));
      expect(last.getTranslation().y, closeTo(20, 0.5));

      await _pointerUp(tester, at: const Offset(80, 70), pointer: 1);
      expect(rec.strokeStarts, isEmpty);
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.idle);
    });

    testWidgets('drawing → pinching cancels the in-flight stroke', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: true, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(100, 100),
        pointer: 1,
      );
      await _pointerMove(tester, to: const Offset(110, 110), pointer: 1);
      expect(rec.strokeStarts, hasLength(1));
      expect(rec.strokeMoves, hasLength(1));

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(200, 200),
        pointer: 2,
      );
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.pinching);
      expect(rec.strokeCancels, 1);
      expect(rec.strokeEnds, 0);
    });

    testWidgets('pinch widening increases scale', (tester) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(100, 100),
        pointer: 1,
      );
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(200, 100),
        pointer: 2,
      );
      // Spread 100 → 200 (2x). Move pointers apart symmetrically.
      await _pointerMove(tester, to: const Offset(50, 100), pointer: 1);
      await _pointerMove(tester, to: const Offset(250, 100), pointer: 2);

      final st = _stateOf(tester, key);
      expect(st.phase, CanvasGesturePhase.pinching);
      final scale = st.transform.getMaxScaleOnAxis();
      expect(scale, closeTo(2.0, 0.05));
    });

    testWidgets('pinch is clamped by minScale / maxScale', (tester) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(
            rec: rec,
            isToolSelected: false,
            key: key,
            minScale: 0.5,
            maxScale: 1.5,
          ),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(100, 100),
        pointer: 1,
      );
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(200, 100),
        pointer: 2,
      );
      // Push to 10x spread — should clamp to maxScale.
      await _pointerMove(tester, to: const Offset(0, 100), pointer: 1);
      await _pointerMove(tester, to: const Offset(1000, 100), pointer: 2);
      final scale = _stateOf(tester, key).transform.getMaxScaleOnAxis();
      expect(scale, closeTo(1.5, 0.01));
    });

    testWidgets('double-tap zooms to 2x and centers on tap point '
        'when no tool is selected', (tester) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );

      // First tap.
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(300, 200),
        pointer: 1,
      );
      await _pointerUp(tester, at: const Offset(300, 200), pointer: 1);
      // Second tap within window.
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(300, 200),
        pointer: 2,
      );

      final st = _stateOf(tester, key);
      expect(st.transform.getMaxScaleOnAxis(), closeTo(2.0, 0.01));
      // Tap-anchor invariant: T(p) = tapPoint where p = T_old⁻¹(tapPoint)
      // = (300, 200) when T_old = identity. So translation = tap - 2 * p:
      // (300 - 600, 200 - 400) = (-300, -200).
      expect(st.transform.getTranslation().x, closeTo(-300, 0.5));
      expect(st.transform.getTranslation().y, closeTo(-200, 0.5));
    });

    testWidgets('double-tap is suppressed when a tool is selected', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: true, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(300, 200),
        pointer: 1,
      );
      await _pointerUp(tester, at: const Offset(300, 200), pointer: 1);
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(300, 200),
        pointer: 2,
      );

      // Should still be drawing — no zoom applied.
      final st = _stateOf(tester, key);
      expect(st.transform.getMaxScaleOnAxis(), closeTo(1.0, 0.01));
      // First tap committed a (zero-length) stroke; second tap started a
      // new stroke. Both `start` callbacks fired.
      expect(rec.strokeStarts, hasLength(2));
    });

    testWidgets('PointerCancel during drawing fires onStrokeCancel', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: true, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(50, 50),
        pointer: 1,
      );
      await _pointerMove(tester, to: const Offset(60, 60), pointer: 1);
      await _pointerCancel(tester, at: const Offset(60, 60), pointer: 1);

      expect(rec.strokeCancels, 1);
      expect(rec.strokeEnds, 0);
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.idle);
    });

    testWidgets('switching tool off mid-stroke cancels the stroke', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');

      Widget build({required bool tool}) => MaterialApp(
        home: _harness(rec: rec, isToolSelected: tool, key: key),
      );

      await tester.pumpWidget(build(tool: true));
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(40, 40),
        pointer: 1,
      );
      expect(rec.strokeStarts, hasLength(1));

      // Toggle the tool off — the widget should cancel the stroke.
      await tester.pumpWidget(build(tool: false));
      expect(rec.strokeCancels, 1);
    });

    testWidgets('pinching → all pointers lift → idle (no fall-back pan)', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('canvas');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(100, 100),
        pointer: 1,
      );
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(200, 100),
        pointer: 2,
      );
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.pinching);

      await _pointerUp(tester, at: const Offset(200, 100), pointer: 2);
      // Spec: one pointer remaining after pinch → idle, not panning.
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.idle);

      await _pointerUp(tester, at: const Offset(100, 100), pointer: 1);
      expect(_stateOf(tester, key).phase, CanvasGesturePhase.idle);
    });

    // VL-7 regression: lifting one finger from a 3-pointer pinch must NOT
    // jump the zoom. The fix is that _applyTransition re-seeds the pinch
    // baseline on EVERY transition that lands in `pinching` (not just on a
    // phase *change*), so when the active pair changes the scale ratio
    // resets to 1 instead of being computed against the stale pair's spread.
    testWidgets('lifting one of three pinch fingers does not jump the zoom', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('vl7');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );
      final state = _stateOf(tester, key);

      // Two fingers down → pinching; spread them apart to zoom in.
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(100, 300),
        pointer: 1,
      );
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(300, 300),
        pointer: 2,
      );
      await _pointerMove(tester, to: const Offset(50, 300), pointer: 1);
      await _pointerMove(tester, to: const Offset(350, 300), pointer: 2);
      expect(state.phase, CanvasGesturePhase.pinching);

      // Third finger down (ignored for the pair), then lift one of the
      // original two — the surviving pair is now (2, 3).
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(200, 100),
        pointer: 3,
      );
      final scaleBeforeLift = state.debugTransform.getMaxScaleOnAxis();
      await _pointerUp(tester, at: const Offset(50, 300), pointer: 1);
      expect(state.phase, CanvasGesturePhase.pinching);

      // Pure pan of the surviving pair (identical deltas → spread constant).
      // With a correct re-seed the ratio is 1, so the scale is unchanged.
      await _pointerMove(tester, to: const Offset(360, 310), pointer: 2);
      await _pointerMove(tester, to: const Offset(210, 110), pointer: 3);
      final scaleAfter = state.debugTransform.getMaxScaleOnAxis();

      expect(
        scaleAfter,
        closeTo(scaleBeforeLift, 0.01),
        reason:
            'pinch baseline was not re-seeded for the new pair → zoom '
            'jumped on finger lift (VL-7 regression)',
      );
    });

    // VL-22 regression: a second finger landing during an in-progress pan
    // must enter pinching, NOT be consumed as a double-tap zoom (which would
    // leave _phase stuck in panning with two pointers down and jump the zoom).
    testWidgets('second finger during a pan enters pinching, not double-tap', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('vl22');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );
      final state = _stateOf(tester, key);

      // First finger down → panning. This also arms the double-tap window
      // (_lastTapPosition / _lastTapAt are set on every pointer-down).
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(100, 100),
        pointer: 1,
      );
      expect(state.phase, CanvasGesturePhase.panning);

      // A second finger lands quickly and nearby — close enough to satisfy the
      // double-tap timing/distance test, which (pre-fix) would zoom + strand
      // the pan. With the guard it falls through to a normal pinch transition.
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(108, 106),
        pointer: 2,
      );

      expect(state.phase, CanvasGesturePhase.pinching);
      expect(
        state.debugTransform.getMaxScaleOnAxis(),
        closeTo(1.0, 0.01),
        reason: 'a double-tap zoom must not fire from the 2nd pan finger',
      );
    });
  });
}
