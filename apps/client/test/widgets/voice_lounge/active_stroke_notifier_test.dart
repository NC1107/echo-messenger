import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_strokes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ActiveStrokeNotifier', () {
    test('start + addPoint + end emit one listener call each', () {
      final n = ActiveStrokeNotifier();
      var fired = 0;
      n.addListener(() => fired++);

      n.start(
        kind: StrokeKind.pen,
        color: '#FF0000',
        width: 3.0,
        first: const CanvasPoint(x: 1, y: 1),
      );
      for (int i = 0; i < 5; i++) {
        n.addPoint(CanvasPoint(x: 2.0 + i, y: 2.0 + i));
      }
      n.end();

      // 1 start + 5 adds + 1 end = 7 fires.
      expect(fired, 7);
      expect(n.isActive, isFalse);
      expect(n.current, isNull);
    });

    test('addPoint ignored when no stroke active', () {
      final n = ActiveStrokeNotifier();
      var fired = 0;
      n.addListener(() => fired++);
      n.addPoint(const CanvasPoint(x: 1, y: 1));
      expect(fired, 0);
      expect(n.current, isNull);
    });

    test('cancel clears state without committing', () {
      final n = ActiveStrokeNotifier();
      n.start(
        kind: StrokeKind.pen,
        color: '#FFFFFF',
        width: 3.0,
        first: const CanvasPoint(x: 0, y: 0),
      );
      n.addPoint(const CanvasPoint(x: 1, y: 1));
      var fired = 0;
      n.addListener(() => fired++);
      n.cancel();
      expect(fired, 1);
      expect(n.isActive, isFalse);
      expect(n.current, isNull);
    });

    test('shape kinds replace trailing point rather than appending', () {
      final n = ActiveStrokeNotifier();
      n.start(
        kind: StrokeKind.rect,
        color: '#00FF00',
        width: 2.0,
        first: const CanvasPoint(x: 10, y: 10),
      );
      n.addPoint(const CanvasPoint(x: 20, y: 20));
      n.addPoint(const CanvasPoint(x: 30, y: 30));
      n.addPoint(const CanvasPoint(x: 40, y: 40));
      final snap = n.current!;
      // First-point preserved, trailing point always reflects latest sample.
      expect(snap.points.length, 2);
      expect(snap.points.first.x, 10);
      expect(snap.points.last.x, 40);
    });

    test('current exposes an unmodifiable list', () {
      final n = ActiveStrokeNotifier();
      n.start(
        kind: StrokeKind.pen,
        color: '#FFFFFF',
        width: 3.0,
        first: const CanvasPoint(x: 0, y: 0),
      );
      final snap = n.current!;
      expect(
        () => snap.points.add(const CanvasPoint(x: 99, y: 99)),
        throwsUnsupportedError,
      );
    });

    test('starting a new stroke resets previous in-flight points', () {
      final n = ActiveStrokeNotifier();
      n.start(
        kind: StrokeKind.pen,
        color: '#FFFFFF',
        width: 3.0,
        first: const CanvasPoint(x: 0, y: 0),
      );
      n.addPoint(const CanvasPoint(x: 1, y: 1));
      n.addPoint(const CanvasPoint(x: 2, y: 2));
      n.start(
        kind: StrokeKind.line,
        color: '#00FF00',
        width: 5.0,
        first: const CanvasPoint(x: 100, y: 100),
      );
      final snap = n.current!;
      expect(snap.kind, StrokeKind.line);
      expect(snap.points.length, 1);
      expect(snap.points.first.x, 100);
    });
  });
}
