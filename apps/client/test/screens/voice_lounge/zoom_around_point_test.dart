import 'package:echo_app/src/widgets/voice_lounge/lounge_canvas_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads the lounge canvas's pan-and-zoom transform sanity for the
/// double-tap gesture. The hard invariant: after a zoom, the canvas
/// pixel that was under the user's finger stays under their finger
/// (within sub-pixel tolerance) — and the new transform reports the
/// requested scale.
///
/// Pre-rewrite this exercised a top-level `zoomAroundPoint` in
/// voice_lounge_screen.dart. That helper was deduplicated against the
/// identical `zoomAround` inside `lounge_canvas_gestures.dart` (the
/// only post-integration caller of the math); the test now points at
/// the surviving copy.
void main() {
  group('zoomAround (lounge canvas gestures)', () {
    test('keeps the tapped point anchored at identity start', () {
      const tap = Offset(120, 80);
      const target = 2.0;
      final result = zoomAround(Matrix4.identity(), tap, target);
      final projected = MatrixUtils.transformPoint(
        result,
        const Offset(120, 80),
      );
      expect((projected - tap).distance, lessThan(1.0));
      expect(result.getMaxScaleOnAxis(), closeTo(target, 1e-9));
    });

    test('anchors the tap after a non-trivial existing pan + zoom', () {
      final start = Matrix4.identity()
        ..scaleByDouble(1.5, 1.5, 1.5, 1)
        ..setTranslationRaw(40, 20, 0);
      const tap = Offset(300, 200);
      const target = 3.0;

      final invStart = Matrix4.copy(start)..invert();
      final canvasUnderTap = MatrixUtils.transformPoint(invStart, tap);

      final result = zoomAround(start, tap, target);

      final projected = MatrixUtils.transformPoint(result, canvasUnderTap);
      expect((projected - tap).distance, lessThan(0.001));
      expect(result.getMaxScaleOnAxis(), closeTo(target, 1e-9));
    });

    test('produces a pure scale + translate (no rotation or shear)', () {
      final start = Matrix4.identity()
        ..scaleByDouble(0.5, 0.5, 0.5, 1)
        ..setTranslationRaw(-200, -120, 0);
      final result = zoomAround(start, const Offset(64, 96), 2.0);
      final s = result.storage;
      expect(s[1], closeTo(0, 1e-9));
      expect(s[2], closeTo(0, 1e-9));
      expect(s[4], closeTo(0, 1e-9));
      expect(s[6], closeTo(0, 1e-9));
      expect(result.getTranslation().z, closeTo(0, 1e-9));
    });

    test('zoom-out (targetScale < currentScale) also anchors the tap', () {
      final start = Matrix4.identity()
        ..scaleByDouble(4.0, 4.0, 4.0, 1)
        ..setTranslationRaw(-1500, -1100, 0);
      const tap = Offset(220, 160);
      const target = 1.5;
      final invStart = Matrix4.copy(start)..invert();
      final canvasUnderTap = MatrixUtils.transformPoint(invStart, tap);
      final result = zoomAround(start, tap, target);
      final projected = MatrixUtils.transformPoint(result, canvasUnderTap);
      expect((projected - tap).distance, lessThan(0.001));
      expect(result.getMaxScaleOnAxis(), closeTo(target, 1e-9));
    });

    test('translation column matches the closed-form expectation', () {
      const tap = Offset(500, 300);
      const target = 2.0;
      final start = Matrix4.identity()
        ..scaleByDouble(1.0, 1.0, 1.0, 1)
        ..setTranslationRaw(100, 50, 0);
      final invStart = Matrix4.copy(start)..invert();
      final canvasPoint = MatrixUtils.transformPoint(invStart, tap);
      final result = zoomAround(start, tap, target);
      final translation = result.getTranslation();
      expect(translation.x, closeTo(tap.dx - canvasPoint.dx * target, 1e-9));
      expect(translation.y, closeTo(tap.dy - canvasPoint.dy * target, 1e-9));
      expect(translation.z, closeTo(0, 1e-9));
    });
  });
}
