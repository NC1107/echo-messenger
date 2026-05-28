import 'package:echo_app/src/screens/voice_lounge_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads the lounge canvas's pan-and-zoom transform sanity for the
/// double-tap gesture. The hard invariant: after a zoom, the canvas
/// pixel that was under the user's finger stays under their finger
/// (within sub-pixel tolerance) — and the new transform reports the
/// requested scale.
void main() {
  group('zoomAroundPoint', () {
    test('keeps the tapped point anchored at identity start', () {
      const tap = Offset(120, 80);
      const target = 2.0;
      final result = zoomAroundPoint(
        current: Matrix4.identity(),
        tapPoint: tap,
        targetScale: target,
      );
      // At identity, canvas coords == viewport coords, so the canvas
      // pixel under the tap is (120, 80). After zoom, that same
      // canvas pixel must land back on (120, 80).
      final projected = MatrixUtils.transformPoint(
        result,
        const Offset(120, 80),
      );
      expect((projected - tap).distance, lessThan(1.0));
      expect(result.getMaxScaleOnAxis(), closeTo(target, 1e-9));
    });

    test('anchors the tap after a non-trivial existing pan + zoom', () {
      // Simulate a user already at 1.5× scale with a (40, 20) pan.
      final start = Matrix4.identity()
        ..scaleByDouble(1.5, 1.5, 1.5, 1)
        ..setTranslationRaw(40, 20, 0);
      const tap = Offset(300, 200);
      const target = 3.0;

      // Canvas-space point currently under the tap.
      final invStart = Matrix4.copy(start)..invert();
      final canvasUnderTap = MatrixUtils.transformPoint(invStart, tap);

      final result = zoomAroundPoint(
        current: start,
        tapPoint: tap,
        targetScale: target,
      );

      // Same canvas pixel must still project to the tap under the
      // new transform.
      final projected = MatrixUtils.transformPoint(result, canvasUnderTap);
      expect((projected - tap).distance, lessThan(0.001));
      expect(result.getMaxScaleOnAxis(), closeTo(target, 1e-9));
    });

    test('produces a pure scale + translate (no rotation or shear)', () {
      final start = Matrix4.identity()
        ..scaleByDouble(0.5, 0.5, 0.5, 1)
        ..setTranslationRaw(-200, -120, 0);
      final result = zoomAroundPoint(
        current: start,
        tapPoint: const Offset(64, 96),
        targetScale: 2.0,
      );
      // Off-diagonal rotation/shear entries must be zero so the
      // canvas isn't squished or twisted by the zoom.
      final s = result.storage;
      expect(s[1], closeTo(0, 1e-9)); // row1, col0
      expect(s[2], closeTo(0, 1e-9)); // row2, col0
      expect(s[4], closeTo(0, 1e-9)); // row0, col1
      expect(s[6], closeTo(0, 1e-9)); // row2, col1
      // Translation Z must be zero so depth stays neutral.
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
      final result = zoomAroundPoint(
        current: start,
        tapPoint: tap,
        targetScale: target,
      );
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
      final result = zoomAroundPoint(
        current: start,
        tapPoint: tap,
        targetScale: target,
      );
      final translation = result.getTranslation();
      expect(translation.x, closeTo(tap.dx - canvasPoint.dx * target, 1e-9));
      expect(translation.y, closeTo(tap.dy - canvasPoint.dy * target, 1e-9));
      // Depth-row stays untouched so 2D math is preserved.
      expect(translation.z, closeTo(0, 1e-9));
    });
  });
}
