import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/canvas_models.dart';
import 'package:echo_app/src/widgets/puck_trail.dart';

void main() {
  group('PuckTrail', () {
    test('starts empty', () {
      final trail = PuckTrail();
      expect(trail.isEmpty, isTrue);
      expect(trail.samples, isEmpty);
    });

    test('addSample appends to the buffer', () {
      final trail = PuckTrail();
      final t0 = DateTime(2026, 1, 1);
      trail.addSample(const CanvasPoint(x: 0.5, y: 0.5), t0);
      trail.addSample(
        const CanvasPoint(x: 0.6, y: 0.5),
        t0.add(const Duration(milliseconds: 50)),
      );
      expect(trail.samples, hasLength(2));
      expect(trail.isEmpty, isFalse);
    });

    test('buffer caps at maxSamples (oldest dropped)', () {
      final trail = PuckTrail(maxSamples: 3);
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 10; i++) {
        trail.addSample(
          CanvasPoint(x: i / 10.0, y: 0.5),
          t0.add(Duration(milliseconds: i * 10)),
        );
      }
      expect(trail.samples, hasLength(3));
      // The first kept sample is index 7 (i*10 = 70ms).
      expect(trail.samples.first.at.difference(t0).inMilliseconds, 70);
      expect(trail.samples.last.at.difference(t0).inMilliseconds, 90);
    });

    test('prune drops samples older than ttl', () {
      final trail = PuckTrail(ttl: const Duration(milliseconds: 200));
      final t0 = DateTime(2026, 1, 1);
      trail.addSample(const CanvasPoint(x: 0.1, y: 0.5), t0);
      trail.addSample(
        const CanvasPoint(x: 0.2, y: 0.5),
        t0.add(const Duration(milliseconds: 100)),
      );
      trail.addSample(
        const CanvasPoint(x: 0.3, y: 0.5),
        t0.add(const Duration(milliseconds: 250)),
      );
      trail.prune(t0.add(const Duration(milliseconds: 300)));
      // First two are now > 200ms old; only the last survives.
      expect(trail.samples, hasLength(1));
      expect(trail.samples.single.pos.x, closeTo(0.3, 1e-9));
    });

    test('render returns offsets relative to current in pixel space', () {
      final trail = PuckTrail();
      final t0 = DateTime(2026, 1, 1);
      // Sample at (0.4, 0.5), current is (0.5, 0.5).  Canvas 1000x500.
      trail.addSample(const CanvasPoint(x: 0.4, y: 0.5), t0);
      final rendered = trail.render(
        current: const CanvasPoint(x: 0.5, y: 0.5),
        canvasSize: const Size(1000, 500),
        now: t0.add(const Duration(milliseconds: 100)),
      );
      expect(rendered, hasLength(1));
      // dx = (0.4 - 0.5) * 1000 = -100 ; dy = 0.
      expect(rendered.single.offset.dx, closeTo(-100, 1e-9));
      expect(rendered.single.offset.dy, closeTo(0, 1e-9));
    });

    test('render fades opacity linearly toward ttl', () {
      final trail = PuckTrail(ttl: const Duration(milliseconds: 600));
      final t0 = DateTime(2026, 1, 1);
      trail.addSample(const CanvasPoint(x: 0.5, y: 0.5), t0);
      // Half-life: 300ms in ⇒ ~0.5 opacity.
      final rendered = trail.render(
        current: const CanvasPoint(x: 0.5, y: 0.5),
        canvasSize: const Size(100, 100),
        now: t0.add(const Duration(milliseconds: 300)),
      );
      expect(rendered.single.opacity, closeTo(0.5, 0.01));
    });

    test(
      'render filters out samples already past ttl without mutating buffer',
      () {
        final trail = PuckTrail(ttl: const Duration(milliseconds: 100));
        final t0 = DateTime(2026, 1, 1);
        trail.addSample(const CanvasPoint(x: 0.1, y: 0.5), t0);
        trail.addSample(
          const CanvasPoint(x: 0.2, y: 0.5),
          t0.add(const Duration(milliseconds: 50)),
        );
        final rendered = trail.render(
          current: const CanvasPoint(x: 0.3, y: 0.5),
          canvasSize: const Size(100, 100),
          now: t0.add(const Duration(milliseconds: 200)),
        );
        expect(rendered, isEmpty, reason: 'all samples expired');
        // Buffer stays intact for prune() to evict on its own.
        expect(trail.samples, hasLength(2));
      },
    );

    test('clear empties the buffer', () {
      final trail = PuckTrail();
      final t0 = DateTime(2026, 1, 1);
      trail.addSample(const CanvasPoint(x: 0.5, y: 0.5), t0);
      trail.clear();
      expect(trail.isEmpty, isTrue);
    });

    test('asserts non-positive maxSamples and ttl', () {
      expect(() => PuckTrail(maxSamples: 0), throwsAssertionError);
      expect(() => PuckTrail(ttl: Duration.zero), throwsAssertionError);
    });
  });
}
