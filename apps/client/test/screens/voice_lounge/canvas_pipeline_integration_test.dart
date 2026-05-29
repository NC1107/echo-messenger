// Integration test for the canvas-rewrite pipeline as wired into the
// voice lounge screen.
//
// Reproduces the lounge's stroke pipeline in miniature: a
// `LoungeCanvasGestures` surface, an `ActiveStrokeNotifier`, and a real
// `canvasProvider`. Drives synthetic pointer events through the gesture
// widget and asserts the two invariants the lounge integration relies on:
//
//   1. During an in-flight stroke, the local preview lives only in the
//      `ActiveStrokeNotifier`; the canvas provider's `strokes` list stays
//      empty until pointer-up.
//   2. Pointer-up commits the stroke (notifier clears, provider's strokes
//      grows by one); pointer-cancel mid-stroke drops the stroke entirely
//      (notifier clears, provider's strokes does NOT grow).
//
// This pins the contract documented in
// docs/voice-lounge/05-canvas-rewrite-spec.md §B.1 + §B.2.

import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/providers/canvas_provider.dart';
import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_gestures.dart';
import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_strokes.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// CanvasController test double — records the start/continue/end lifecycle
// and synthesises the same `state.strokes` append that the real provider
// performs on a successful endStroke. Bypasses the `_channelId == null`
// guard inside endStroke so the test doesn't need a running server.
// ---------------------------------------------------------------------------

class _OfflineCanvas extends CanvasController {
  final List<CanvasPoint> _buf = <CanvasPoint>[];
  bool _active = false;

  @override
  void startStroke(CanvasPoint point) {
    _buf
      ..clear()
      ..add(point);
    _active = true;
  }

  @override
  void continueStroke(CanvasPoint point) {
    if (!_active) return;
    _buf.add(point);
  }

  @override
  void endStroke() {
    if (!_active) return;
    _active = false;
    if (_buf.isEmpty) return;
    final stroke = CanvasStroke(
      id: 'test-${DateTime.now().microsecondsSinceEpoch}',
      color: '#FFFFFF',
      width: 3.0,
      points: List<CanvasPoint>.from(_buf),
      kind: StrokeKind.pen,
    );
    _buf.clear();
    state = state.copyWith(
      strokes: List<CanvasStroke>.from(state.strokes)..add(stroke),
    );
  }

  @override
  void cancelStroke() {
    _active = false;
    _buf.clear();
  }
}

// ---------------------------------------------------------------------------
// Synthetic pointer dispatch helpers (same shape as the gesture-widget
// tests so behaviour is comparable).
// ---------------------------------------------------------------------------

Future<void> _down(WidgetTester t, Offset at, int id) async {
  final hits = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hits, at, t.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerDownEvent(pointer: id, position: at),
    hits,
  );
  await t.pump();
}

Future<void> _move(WidgetTester t, Offset to, int id) async {
  final hits = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hits, to, t.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerMoveEvent(pointer: id, position: to),
    hits,
  );
  await t.pump();
}

Future<void> _up(WidgetTester t, Offset at, int id) async {
  final hits = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hits, at, t.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerUpEvent(pointer: id, position: at),
    hits,
  );
  await t.pump();
}

Future<void> _cancel(WidgetTester t, Offset at, int id) async {
  final hits = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hits, at, t.view.viewId);
  WidgetsBinding.instance.dispatchEvent(
    PointerCancelEvent(pointer: id, position: at),
    hits,
  );
  await t.pump();
}

// ---------------------------------------------------------------------------
// Harness: same wiring the lounge uses (gesture surface → strokes painter
// + active-stroke notifier → canvas provider for the WS path).
// ---------------------------------------------------------------------------

class _PipelineHarness extends ConsumerStatefulWidget {
  const _PipelineHarness({required this.notifier});
  final ActiveStrokeNotifier notifier;

  @override
  ConsumerState<_PipelineHarness> createState() => _PipelineHarnessState();
}

class _PipelineHarnessState extends ConsumerState<_PipelineHarness> {
  void _onStart(Offset p) {
    final pt = CanvasPoint(x: p.dx, y: p.dy);
    widget.notifier.start(
      kind: StrokeKind.pen,
      color: '#FFFFFF',
      width: 3.0,
      first: pt,
    );
    ref.read(canvasProvider.notifier).startStroke(pt);
  }

  void _onMove(Offset p) {
    final pt = CanvasPoint(x: p.dx, y: p.dy);
    widget.notifier.addPoint(pt);
    ref.read(canvasProvider.notifier).continueStroke(pt);
  }

  void _onEnd() {
    widget.notifier.end();
    ref.read(canvasProvider.notifier).endStroke();
  }

  void _onCancel() {
    widget.notifier.cancel();
    ref.read(canvasProvider.notifier).cancelStroke();
  }

  @override
  Widget build(BuildContext context) {
    final canvas = ref.watch(canvasProvider);
    return MaterialApp(
      home: Scaffold(
        body: LoungeCanvasGestures(
          isToolSelected: true,
          initialTransform: Matrix4.identity(),
          onStrokeStart: _onStart,
          onStrokeMove: _onMove,
          onStrokeEnd: _onEnd,
          onStrokeCancel: _onCancel,
          child: SizedBox(
            width: 800,
            height: 600,
            child: LoungeCanvasStrokes(
              committedStrokes: canvas.strokes,
              activeStroke: widget.notifier,
              background: const ColoredBox(color: Color(0xFF202020)),
            ),
          ),
        ),
      ),
    );
  }
}

Future<ActiveStrokeNotifier> _pumpPipeline(WidgetTester t) async {
  final notifier = ActiveStrokeNotifier();
  await t.pumpWidget(
    ProviderScope(
      overrides: [canvasProvider.overrideWith(() => _OfflineCanvas())],
      child: _PipelineHarness(notifier: notifier),
    ),
  );
  await t.pump();
  return notifier;
}

void main() {
  testWidgets(
    'pointer-down + move keeps the in-flight stroke local; no commit yet',
    (tester) async {
      final notifier = await _pumpPipeline(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LoungeCanvasGestures)),
      );

      const start = Offset(100, 100);
      const mid = Offset(120, 120);

      await _down(tester, start, 1);
      await _move(tester, mid, 1);

      // Notifier reflects the in-flight stroke …
      final snap = notifier.current;
      expect(snap, isNotNull, reason: 'in-flight stroke should be present');
      expect(snap!.points.length, greaterThanOrEqualTo(2));
      expect(notifier.isActive, isTrue);

      // … but the canvas provider has NOT committed it.
      expect(container.read(canvasProvider).strokes, isEmpty);

      // Clean up by lifting the pointer so the test exits with no
      // dangling gesture state.
      await _up(tester, mid, 1);
    },
  );

  testWidgets('pointer-up commits the stroke', (tester) async {
    final notifier = await _pumpPipeline(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoungeCanvasGestures)),
    );

    const start = Offset(200, 200);
    const next = Offset(240, 220);

    await _down(tester, start, 2);
    await _move(tester, next, 2);
    await _up(tester, next, 2);

    // Notifier cleared.
    expect(notifier.isActive, isFalse);
    expect(notifier.current, isNull);

    // Provider gained one stroke.
    final strokes = container.read(canvasProvider).strokes;
    expect(strokes.length, 1);
    expect(strokes.first.kind, StrokeKind.pen);
    expect(strokes.first.points, isNotEmpty);
  });

  testWidgets(
    'pointer-cancel mid-stroke drops the stroke (notifier clears, no commit)',
    (tester) async {
      final notifier = await _pumpPipeline(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LoungeCanvasGestures)),
      );

      const start = Offset(300, 300);
      const mid = Offset(320, 320);

      await _down(tester, start, 3);
      await _move(tester, mid, 3);
      // Cancel the single pointer the way a touch driver would deliver
      // a PointerCancelEvent (system gesture pre-empted the stream).
      await _cancel(tester, mid, 3);

      // Notifier cleared without committing.
      expect(notifier.isActive, isFalse);
      expect(notifier.current, isNull);

      // No stroke ever landed on the canvas provider.
      expect(container.read(canvasProvider).strokes, isEmpty);
    },
  );
}
