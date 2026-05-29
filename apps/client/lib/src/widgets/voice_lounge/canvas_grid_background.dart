import 'package:flutter/material.dart';

/// Maximum number of minor grid lines drawn per axis before the effective
/// spacing is multiplied by 10x to keep painting cheap.
const int _kMaxLinesPerAxis = 200;

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

    final effectiveSpacing = _resolveSpacing(
      visibleLeft,
      visibleRight,
      visibleTop,
      visibleBottom,
    );

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

  /// Returns the effective minor spacing so that at most [_kMaxLinesPerAxis]
  /// lines are drawn per axis. Multiplies by 10x per step until the count fits.
  double _resolveSpacing(double left, double right, double top, double bottom) {
    final spanX = right - left;
    final spanY = bottom - top;
    final maxSpan = spanX > spanY ? spanX : spanY;

    var spacing = minorSpacing;
    while (maxSpan / spacing > _kMaxLinesPerAxis) {
      spacing *= 10;
    }
    return spacing;
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
