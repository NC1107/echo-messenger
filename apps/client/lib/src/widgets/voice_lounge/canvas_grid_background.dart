import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Target on-screen gap (logical px) between minor grid lines. The effective
/// canvas-space spacing is chosen per-frame from the current zoom so the grid
/// stays around this density at any scale — giving the user a constant sense
/// of scale as they zoom (lines subdivide when zooming in, coarsen when
/// zooming out) instead of spreading apart or vanishing.
const double _kTargetMinorScreenPx = 80.0;

/// Minor-line stroke width (logical pixels).
const double _kMinorStrokeWidth = 0.5;

/// Major-line stroke width (logical pixels).
const double _kMajorStrokeWidth = 1.0;

/// Voice-lounge canvas background that renders a Figma/Miro-style grid.
///
/// Minor grid lines at [minorSpacing] canvas-world pixels. A slightly heavier
/// major line every [majorEvery] minor cells. Both lines reproject correctly
/// on every pan/zoom frame, giving the user visible scale information that
/// the old `VertexMeshBackground` could not provide.
///
/// The widget listens to [transformListenable] (typically the
/// `TransformationController` used by the lounge's gesture layer) and reads
/// the current `Matrix4` via [currentTransform] on each repaint. The
/// `CustomPainter` + `RepaintBoundary` keep grid repaints isolated from the
/// stroke layer above.
class CanvasGridBackground extends StatelessWidget {
  const CanvasGridBackground({
    super.key,
    required this.transformListenable,
    required this.currentTransform,
    this.minorSpacing = 100.0,
    this.majorEvery = 5,
  });

  /// Notifier that fires whenever the canvas transform changes (e.g.
  /// `TransformationController`). Drives selective grid repaints.
  final Listenable transformListenable;

  /// Returns the current viewport-to-canvas `Matrix4`. Called on every repaint.
  final Matrix4 Function() currentTransform;

  /// Minor grid spacing in canvas-world pixels.
  final double minorSpacing;

  /// A major line is drawn every [majorEvery] minor cells.
  final int majorEvery;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _GridPainter(
          transformListenable: transformListenable,
          currentTransform: currentTransform,
          minorSpacing: minorSpacing,
          majorEvery: majorEvery,
          isDark: isDark,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.transformListenable,
    required this.currentTransform,
    required this.minorSpacing,
    required this.majorEvery,
    required this.isDark,
  }) : super(repaint: transformListenable);

  final Listenable transformListenable;
  final Matrix4 Function() currentTransform;
  final double minorSpacing;
  final int majorEvery;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final matrix = currentTransform();

    // Unproject screen corners to canvas-world space.
    final invMatrix = Matrix4.inverted(matrix);
    final topLeft = _unproject(invMatrix, 0, 0);
    final bottomRight = _unproject(invMatrix, size.width, size.height);

    final visibleLeft = topLeft.dx;
    final visibleRight = bottomRight.dx;
    final visibleTop = topLeft.dy;
    final visibleBottom = bottomRight.dy;

    final effectiveSpacing = _resolveSpacing(matrix);

    final majorSpacing = effectiveSpacing * majorEvery;

    final minorPaint = _buildMinorPaint();
    final majorPaint = _buildMajorPaint();

    _drawVerticalLines(
      canvas,
      size,
      matrix,
      visibleLeft,
      visibleRight,
      effectiveSpacing,
      majorSpacing,
      minorPaint,
      majorPaint,
    );

    _drawHorizontalLines(
      canvas,
      size,
      matrix,
      visibleTop,
      visibleBottom,
      effectiveSpacing,
      majorSpacing,
      minorPaint,
      majorPaint,
    );
  }

  /// Unprojects a screen-space point to canvas-world space using the inverted
  /// transform matrix. Uses `MatrixUtils.transformPoint` (flutter-native, no
  /// extra package import).
  Offset _unproject(Matrix4 inv, double sx, double sy) {
    return MatrixUtils.transformPoint(inv, Offset(sx, sy));
  }

  /// Projects a canvas-world point back to screen space.
  Offset _project(Matrix4 m, double cx, double cy) {
    return MatrixUtils.transformPoint(m, Offset(cx, cy));
  }

  /// Chooses the minor-grid spacing (in canvas-world px) for the current zoom
  /// so the on-screen gap stays near [_kTargetMinorScreenPx]. Snaps to a
  /// 1-2-5 x 10ⁿ sequence (like a ruler / Figma / Miro) so the lines land on
  /// round numbers, and adapts both ways — subdividing when zoomed in and
  /// coarsening when zoomed out. This also naturally bounds the visible line
  /// count (~viewport / target), so no separate count cap is needed.
  double _resolveSpacing(Matrix4 matrix) {
    final scale = matrix.getMaxScaleOnAxis();
    if (scale <= 0 || !scale.isFinite) return minorSpacing;
    return niceGridStep(_kTargetMinorScreenPx / scale, fallback: minorSpacing);
  }

  Paint _buildMinorPaint() {
    final color = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.grey.shade300;
    return Paint()
      ..color = color
      ..strokeWidth = _kMinorStrokeWidth
      ..strokeCap = StrokeCap.square;
  }

  Paint _buildMajorPaint() {
    final color = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.grey.shade400;
    return Paint()
      ..color = color
      ..strokeWidth = _kMajorStrokeWidth
      ..strokeCap = StrokeCap.square;
  }

  void _drawVerticalLines(
    Canvas canvas,
    Size size,
    Matrix4 matrix,
    double visibleLeft,
    double visibleRight,
    double spacing,
    double majorSpacing,
    Paint minorPaint,
    Paint majorPaint,
  ) {
    final firstX = (visibleLeft / spacing).floor() * spacing;
    var cx = firstX;
    while (cx <= visibleRight) {
      final screenX = _project(matrix, cx, 0).dx;
      final paint = _isMajor(cx, majorSpacing) ? majorPaint : minorPaint;
      canvas.drawLine(Offset(screenX, 0), Offset(screenX, size.height), paint);
      cx += spacing;
    }
  }

  void _drawHorizontalLines(
    Canvas canvas,
    Size size,
    Matrix4 matrix,
    double visibleTop,
    double visibleBottom,
    double spacing,
    double majorSpacing,
    Paint minorPaint,
    Paint majorPaint,
  ) {
    final firstY = (visibleTop / spacing).floor() * spacing;
    var cy = firstY;
    while (cy <= visibleBottom) {
      final screenY = _project(matrix, 0, cy).dy;
      final paint = _isMajor(cy, majorSpacing) ? majorPaint : minorPaint;
      canvas.drawLine(Offset(0, screenY), Offset(size.width, screenY), paint);
      cy += spacing;
    }
  }

  /// Returns true when [value] is a multiple of [majorSpacing] within a
  /// floating-point tolerance of half the minor spacing.
  bool _isMajor(double value, double majorSpacing) {
    final remainder = value % majorSpacing;
    final tolerance = minorSpacing * 0.5;
    return remainder < tolerance || (majorSpacing - remainder) < tolerance;
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.minorSpacing != minorSpacing ||
      old.majorEvery != majorEvery ||
      old.isDark != isDark;
}

/// Rounds [value] to the nearest 1-2-5 x 10ⁿ "nice" step (like a ruler).
/// Used to pick an adaptive grid spacing from the desired on-screen gap so
/// the grid subdivides as you zoom in and coarsens as you zoom out. Returns
/// [fallback] for non-positive / non-finite input. Pure + public for tests.
@visibleForTesting
double niceGridStep(double value, {double fallback = 100.0}) {
  if (value <= 0 || !value.isFinite) return fallback;
  final exponent = (math.log(value) / math.ln10).floor();
  final pow10 = math.pow(10, exponent).toDouble();
  final fraction = value / pow10; // in [1, 10)
  final double nice;
  if (fraction < 1.5) {
    nice = 1.0;
  } else if (fraction < 3.5) {
    nice = 2.0;
  } else if (fraction < 7.5) {
    nice = 5.0;
  } else {
    nice = 10.0;
  }
  return nice * pow10;
}
