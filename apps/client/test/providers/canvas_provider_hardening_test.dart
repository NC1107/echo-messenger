// Regression tests for the voice-lounge crash/sync hardening batch
// (VL-1, VL-4, VL-5, VL-6). Unlike canvas_provider_test.dart — which
// re-implements the handler switch inline — these drive the REAL
// CanvasController.handleCanvasEvent via a ProviderContainer so a
// regression in the actual ingress path is caught.

import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/providers/canvas_authority_provider.dart';
import 'package:echo_app/src/providers/canvas_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _chan = 'chan-1';

CanvasController _attached(ProviderContainer c) {
  final notifier = c.read(canvasProvider.notifier);
  notifier.debugAttachChannel(_chan);
  return notifier;
}

Map<String, dynamic> _strokeEvent({
  required String id,
  String from = 'peer',
  Object? points,
  Object? width,
  Object? color,
}) => {
  'channel_id': _chan,
  'kind': 'stroke',
  'from_user_id': from,
  'payload': {
    'id': id,
    'color': color ?? '#FF5500',
    'width': width ?? 3.0,
    'points':
        points ??
        [
          {'x': 10000.0, 'y': 20000.0},
          {'x': 30000.0, 'y': 40000.0},
        ],
  },
};

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('VL-1: malformed canvas frames are dropped, not crash-propagated', () {
    test('stroke payload missing required fields does not throw', () {
      final c = makeContainer();
      final n = _attached(c);

      expect(
        () => n.handleCanvasEvent({
          'channel_id': _chan,
          'kind': 'stroke',
          'payload': {'id': 'x'}, // no color/width/points
        }),
        returnsNormally,
      );
      expect(c.read(canvasProvider).strokes, isEmpty);
    });

    test('stroke with wrong-typed fields does not throw', () {
      final c = makeContainer();
      final n = _attached(c);

      expect(
        () => n.handleCanvasEvent(
          _strokeEvent(id: 'x', width: 'not-a-number', points: 'nope'),
        ),
        returnsNormally,
      );
      expect(c.read(canvasProvider).strokes, isEmpty);
    });

    test('image_add with null payload fields does not throw', () {
      final c = makeContainer();
      final n = _attached(c);

      expect(
        () => n.handleCanvasEvent({
          'channel_id': _chan,
          'kind': 'image_add',
          'payload': {'id': 'img1'}, // no url/x/y/width/height
        }),
        returnsNormally,
      );
      expect(c.read(canvasProvider).images, isEmpty);
    });

    test('a malformed frame does not poison subsequent valid frames', () {
      final c = makeContainer();
      final n = _attached(c);

      n.handleCanvasEvent(_strokeEvent(id: 'bad', points: 42));
      n.handleCanvasEvent(_strokeEvent(id: 'good'));

      expect(c.read(canvasProvider).strokes.map((s) => s.id), ['good']);
    });
  });

  group('VL-4: receive-side dedup', () {
    test('duplicate stroke id replaces rather than appends', () {
      final c = makeContainer();
      final n = _attached(c);

      n.handleCanvasEvent(_strokeEvent(id: 'dup'));
      n.handleCanvasEvent(_strokeEvent(id: 'dup'));

      final strokes = c.read(canvasProvider).strokes;
      expect(strokes.length, 1);
      expect(strokes.single.id, 'dup');
    });

    test('duplicate image id replaces rather than appends', () {
      final c = makeContainer();
      final n = _attached(c);

      Map<String, dynamic> img() => {
        'channel_id': _chan,
        'kind': 'image_add',
        'payload': {
          'id': 'img',
          'url': 'https://x/api/media/1',
          'x': 100.0,
          'y': 100.0,
          'width': 50.0,
          'height': 50.0,
        },
      };
      n.handleCanvasEvent(img());
      n.handleCanvasEvent(img());

      expect(c.read(canvasProvider).images.length, 1);
    });
  });

  group('VL-5: client stroke list is capped to the server limit', () {
    test('stays at 2000 after 2050 distinct inbound strokes', () {
      final c = makeContainer();
      final n = _attached(c);

      for (var i = 0; i < 2050; i++) {
        n.handleCanvasEvent(_strokeEvent(id: 'stroke-$i'));
      }

      final strokes = c.read(canvasProvider).strokes;
      expect(strokes.length, 2000);
      // Oldest-first trim: the earliest ids fell off, the newest survive.
      expect(strokes.last.id, 'stroke-2049');
      expect(strokes.first.id, 'stroke-50');
    });
  });

  group('VL-6: remote clear aborts an in-flight local stroke', () {
    test('clear cancels the active stroke so it cannot resurrect', () {
      final c = makeContainer();
      final n = _attached(c);

      // Begin a local stroke (pen tool selected so startStroke takes effect).
      n.setTool(CanvasTool.pen);
      n.startStroke(const CanvasPoint(x: 5000, y: 5000));
      n.continueStroke(const CanvasPoint(x: 6000, y: 6000));
      expect(n.debugIsStrokeActive, isTrue);

      // A remote clear arrives mid-draw.
      n.handleCanvasEvent({
        'channel_id': _chan,
        'kind': 'clear',
        'payload': const <String, dynamic>{},
      });

      expect(n.debugIsStrokeActive, isFalse);

      // The since-aborted stroke must not commit/append on endStroke.
      n.endStroke();
      expect(c.read(canvasProvider).strokes, isEmpty);
    });
  });

  group('VL-12: detach clears per-channel canvas authority', () {
    test('a stale authority device does not survive into the next session', () {
      final c = makeContainer();
      final n = c.read(canvasProvider.notifier);

      // Some other device held the write lock for this channel.
      c.read(canvasAuthorityNotifierProvider(_chan).notifier).setAuthority(7);
      n.debugAttachChannel(_chan);
      expect(c.read(canvasAuthorityNotifierProvider(_chan)), 7);

      n.detach();
      expect(
        c.read(canvasAuthorityNotifierProvider(_chan)),
        isNull,
        reason: 'detach must reset authority so the next join starts clean',
      );
    });
  });

  group('VL-31: degenerate single-point shapes are dropped', () {
    test('single-tap with a shape tool commits nothing', () {
      final c = makeContainer();
      final n = _attached(c);
      n.setTool(CanvasTool.rect);
      n.startStroke(const CanvasPoint(x: 1000, y: 1000)); // tap, no drag
      n.endStroke();
      expect(c.read(canvasProvider).strokes, isEmpty);
    });

    test('a dragged two-point shape commits', () {
      final c = makeContainer();
      final n = _attached(c);
      n.setTool(CanvasTool.rect);
      n.startStroke(const CanvasPoint(x: 1000, y: 1000));
      n.continueStroke(const CanvasPoint(x: 2000, y: 2000));
      n.endStroke();
      final strokes = c.read(canvasProvider).strokes;
      expect(strokes.length, 1);
      expect(strokes.single.kind, StrokeKind.rect);
    });
  });
}
