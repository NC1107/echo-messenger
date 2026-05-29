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
  Size? viewportSize,
  Size? canvasSize,
}) {
  return LoungeCanvasGestures(
    key: key,
    isToolSelected: isToolSelected,
    initialTransform: initial ?? Matrix4.identity(),
    minScale: minScale,
    maxScale: maxScale,
    viewportSize: viewportSize,
    canvasSize: canvasSize,
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

Future<void> _scroll(
  WidgetTester tester, {
  required Offset at,
  required double dy,
}) async {
  final hitTest = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hitTest, at, tester.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerScrollEvent(position: at, scrollDelta: Offset(0, dy)),
    hitTest,
  );
  await tester.pump();
}

/// The matrix actually applied to the canvas child — i.e. the `Transform`
/// widget rendered by the gesture surface. Distinct from `state.transform`
/// (the field): a regression where pan/pinch mutate the field but never
/// rebuild only shows up here.
Matrix4 _renderedTransform(WidgetTester tester, Key key) => tester
    .widget<Transform>(
      find
          .descendant(of: find.byKey(key), matching: find.byType(Transform))
          .first,
    )
    .transform;

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

    // Regression (canvas-rewrite #1278): pan mutated `_transform` and emitted
    // it to the grid, but never setState, so the Transform wrapping the canvas
    // child kept the old matrix — the grid moved while strokes/avatars stayed
    // put. Assert the RENDERED transform follows the pan, not just the field.
    testWidgets('pan moves the rendered canvas transform, not just the field', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('pan-render');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );

      await _pointerDown(
        tester,
        () => null,
        at: const Offset(400, 300),
        pointer: 1,
      );
      await _pointerMove(tester, to: const Offset(460, 340), pointer: 1);

      final rendered = _renderedTransform(tester, key);
      final field = _stateOf(tester, key).debugTransform;
      expect(
        rendered.getTranslation().x,
        closeTo(field.getTranslation().x, 0.01),
      );
      expect(
        rendered.getTranslation().y,
        closeTo(field.getTranslation().y, 0.01),
      );
      // A 60x40 drag must actually have moved the rendered transform.
      expect(rendered.getTranslation().x, closeTo(60, 0.01));
      expect(rendered.getTranslation().y, closeTo(40, 0.01));
    });

    // Regression (canvas-rewrite #1278): desktop scroll-wheel zoom was lost
    // when InteractiveViewer was replaced by the raw Listener. Scroll up must
    // zoom in around the cursor and update the rendered transform.
    testWidgets('mouse-wheel scroll zooms the canvas', (tester) async {
      final rec = _Recorder();
      const key = ValueKey('scroll-zoom');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(rec: rec, isToolSelected: false, key: key),
        ),
      );

      final before = _stateOf(tester, key).debugTransform.getMaxScaleOnAxis();
      await _scroll(tester, at: const Offset(400, 300), dy: -120); // scroll up
      final after = _stateOf(tester, key).debugTransform.getMaxScaleOnAxis();

      expect(after, greaterThan(before), reason: 'scroll up should zoom in');
      expect(
        _renderedTransform(tester, key).getMaxScaleOnAxis(),
        closeTo(after, 0.01),
        reason: 'the rendered transform must reflect the scroll zoom',
      );
    });

    // Bounded-canvas: with viewportSize + canvasSize provided, pan is
    // clamped so the board can't be fully dragged out of view (#29 / #30).
    //
    // New rule (overscroll-margin): margin = min(scaled, viewport) * 0.15.
    // tx ∈ [margin - scaled, viewport - margin].
    //
    // At scale 1, canvas=1000, viewport=800x600:
    //   X: margin = 800*0.15 = 120  → lo = 120-1000 = -880,  hi = 800-120 = 680
    //   Y: margin = 600*0.15 = 90   → lo = 90-1000 = -910,   hi = 600-90  = 510
    //
    // resetToTransform pushes the transform through _clampTransform and is the
    // canonical way to assert the clamp boundary from tests (avoids pointer hit-
    // test coordinate limits in the test harness).
    testWidgets('pan is clamped to the bounded canvas', (tester) async {
      final rec = _Recorder();
      const key = ValueKey('clamp');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(
            rec: rec,
            isToolSelected: false,
            key: key,
            viewportSize: const Size(800, 600),
            canvasSize: const Size(1000, 1000),
          ),
        ),
      );

      final state = _stateOf(tester, key);

      // Push an extreme lo-bound translation: tx = -5000, -5000.
      // At scale 1, canvas=1000, viewport=800x600:
      //   X: margin=120, lo=-880 → clamped to -880
      //   Y: margin=90,  lo=-910 → clamped to -910
      state.resetToTransform(
        Matrix4.identity()..setTranslationRaw(-5000, -5000, 0),
      );
      await tester.pump();
      var t = state.debugTransform.getTranslation();
      expect(t.x, closeTo(-880, 0.01), reason: 'lo-x clamp (#30 escape)');
      expect(t.y, closeTo(-910, 0.01), reason: 'lo-y clamp (#30 escape)');

      // Push an extreme hi-bound translation: tx = +5000, +5000.
      //   X: hi = 800 - 120 = 680
      //   Y: hi = 600 - 90  = 510
      state.resetToTransform(
        Matrix4.identity()..setTranslationRaw(5000, 5000, 0),
      );
      await tester.pump();
      t = state.debugTransform.getTranslation();
      expect(t.x, closeTo(680, 0.01), reason: 'hi-x clamp (#30 escape)');
      expect(t.y, closeTo(510, 0.01), reason: 'hi-y clamp (#30 escape)');
    });

    // When the board is SMALLER than the viewport (zoomed out), the old code
    // force-centered it so panning was impossible (#29). The new overscroll-
    // margin rule keeps the board pannable while staying on-screen.
    testWidgets('zoomed-out board is pannable, not force-centred', (
      tester,
    ) async {
      final rec = _Recorder();
      const key = ValueKey('clamp-small');
      await tester.pumpWidget(
        MaterialApp(
          home: _harness(
            rec: rec,
            isToolSelected: false,
            key: key,
            viewportSize: const Size(800, 600),
            canvasSize: const Size(400, 300), // board smaller than viewport
          ),
        ),
      );

      // Scale=1, canvas=400x300, viewport=800x600.
      // X: margin = 400*0.15=60, lo=60-400=-340, hi=800-60=740.
      // Board IS pannable — the centre (200, 150) is valid, and so is (0, 0).
      await _pointerDown(
        tester,
        () => null,
        at: const Offset(400, 300),
        pointer: 1,
      );
      // Pan left by 100px — should apply freely (tx goes from 0 to -100, within [-340, 740]).
      await _pointerMove(tester, to: const Offset(300, 240), pointer: 1);
      final t = _stateOf(tester, key).debugTransform.getTranslation();
      expect(
        t.x,
        closeTo(-100, 1.0),
        reason: 'zoomed-out board must be pannable left (#29 regression)',
      );
      expect(
        t.y,
        closeTo(-60, 1.0),
        reason: 'zoomed-out board must be pannable up (#29 regression)',
      );
      await _pointerUp(tester, at: const Offset(300, 240), pointer: 1);
    });
  });
}
