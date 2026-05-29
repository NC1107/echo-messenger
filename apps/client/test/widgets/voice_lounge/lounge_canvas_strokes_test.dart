import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_strokes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Picks up every `drawXxx` call so we can assert per-tool path resolution
/// without rendering on a real surface.
class _RecorderCanvas implements Canvas {
  final List<String> calls = <String>[];

  @override
  void noSuchMethod(Invocation i) {
    if (i.isMethod) {
      calls.add(
        i.memberName.toString().replaceAll('Symbol("', '').replaceAll('")', ''),
      );
    }
  }
}

void main() {
  const size = Size(1000, 1000);

  group('paintStroke per-tool resolution', () {
    test('line tool draws a straight line, not an outline polygon', () {
      final c = _RecorderCanvas();
      paintStroke(
        c,
        size,
        const CanvasStroke(
          id: 'l1',
          color: '#FFFFFF',
          width: 3.0,
          kind: StrokeKind.line,
          points: <CanvasPoint>[
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 200, y: 50),
          ],
        ),
      );
      expect(c.calls, contains('drawLine'));
      expect(c.calls, isNot(contains('drawPath')));
    });

    test('rect tool draws a rectangle', () {
      final c = _RecorderCanvas();
      paintStroke(
        c,
        size,
        const CanvasStroke(
          id: 'r1',
          color: '#FFFFFF',
          width: 3.0,
          kind: StrokeKind.rect,
          points: <CanvasPoint>[
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 200, y: 200),
          ],
        ),
      );
      expect(c.calls, contains('drawRect'));
    });

    test('ellipse tool draws an oval', () {
      final c = _RecorderCanvas();
      paintStroke(
        c,
        size,
        const CanvasStroke(
          id: 'e1',
          color: '#FFFFFF',
          width: 3.0,
          kind: StrokeKind.ellipse,
          points: <CanvasPoint>[
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 200, y: 200),
          ],
        ),
      );
      expect(c.calls, contains('drawOval'));
    });

    test('pen tool with multiple points emits a filled outline path', () {
      final c = _RecorderCanvas();
      paintStroke(
        c,
        size,
        const CanvasStroke(
          id: 'p1',
          color: '#FFFFFF',
          width: 4.0,
          kind: StrokeKind.pen,
          points: <CanvasPoint>[
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 20, y: 20),
            CanvasPoint(x: 30, y: 30),
            CanvasPoint(x: 40, y: 40),
          ],
        ),
      );
      // perfect_freehand's outline polygon is rendered as a closed path.
      expect(c.calls, contains('drawPath'));
      expect(c.calls, isNot(contains('drawLine')));
    });

    test('single-point freehand stroke draws a dot', () {
      final c = _RecorderCanvas();
      paintStroke(
        c,
        size,
        const CanvasStroke(
          id: 'p2',
          color: '#FFFFFF',
          width: 4.0,
          kind: StrokeKind.pen,
          points: <CanvasPoint>[CanvasPoint(x: 50, y: 50)],
        ),
      );
      expect(c.calls, contains('drawCircle'));
    });

    test('text stroke does not invoke perfect_freehand', () {
      final c = _RecorderCanvas();
      paintStroke(
        c,
        size,
        const CanvasStroke(
          id: 't1',
          color: '#FFFFFF',
          width: 16.0,
          kind: StrokeKind.text,
          text: 'hello',
          points: <CanvasPoint>[CanvasPoint(x: 5, y: 5)],
        ),
      );
      expect(c.calls, isNot(contains('drawPath')));
    });
  });

  group('paintActiveStroke', () {
    test('uses isComplete=false branch but renders the same shape', () {
      final c = _RecorderCanvas();
      paintActiveStroke(
        c,
        size,
        const ActiveStroke(
          kind: StrokeKind.pen,
          color: '#FFFFFF',
          width: 3.0,
          points: <CanvasPoint>[
            CanvasPoint(x: 1, y: 1),
            CanvasPoint(x: 2, y: 2),
            CanvasPoint(x: 3, y: 3),
          ],
        ),
      );
      expect(c.calls, contains('drawPath'));
    });

    test('shape active strokes draw the underlying primitive', () {
      final c = _RecorderCanvas();
      paintActiveStroke(
        c,
        size,
        const ActiveStroke(
          kind: StrokeKind.line,
          color: '#FFFFFF',
          width: 3.0,
          points: <CanvasPoint>[
            CanvasPoint(x: 0, y: 0),
            CanvasPoint(x: 10, y: 10),
          ],
        ),
      );
      expect(c.calls, contains('drawLine'));
    });

    test('text in active stroke is a no-op (uses tap-to-place flow)', () {
      final c = _RecorderCanvas();
      paintActiveStroke(
        c,
        size,
        const ActiveStroke(
          kind: StrokeKind.text,
          color: '#FFFFFF',
          width: 16.0,
          points: <CanvasPoint>[CanvasPoint(x: 5, y: 5)],
        ),
      );
      expect(c.calls, isEmpty);
    });
  });

  group('LoungeCanvasStrokes widget', () {
    testWidgets('mounts three layers with stroke + active notifier', (
      tester,
    ) async {
      final notifier = ActiveStrokeNotifier();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 400,
            height: 400,
            child: LoungeCanvasStrokes(
              committedStrokes: const <CanvasStroke>[
                CanvasStroke(
                  id: 's1',
                  color: '#FFFFFF',
                  width: 3.0,
                  kind: StrokeKind.pen,
                  points: <CanvasPoint>[
                    CanvasPoint(x: 1, y: 1),
                    CanvasPoint(x: 2, y: 2),
                  ],
                ),
              ],
              activeStroke: notifier,
              background: const ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ),
      );

      final boundaries = find.byType(RepaintBoundary);
      expect(boundaries, findsNWidgets(3));
    });

    testWidgets(
      'addPoint after pump does not throw and is observable in current',
      (tester) async {
        final notifier = ActiveStrokeNotifier();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 400,
              height: 400,
              child: LoungeCanvasStrokes(
                committedStrokes: const <CanvasStroke>[],
                activeStroke: notifier,
                background: const ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        );
        notifier.start(
          kind: StrokeKind.pen,
          color: '#FFFFFF',
          width: 3.0,
          first: const CanvasPoint(x: 1, y: 1),
        );
        notifier.addPoint(const CanvasPoint(x: 2, y: 2));
        await tester.pump();
        expect(notifier.current?.points.length, 2);
      },
    );
  });
}
