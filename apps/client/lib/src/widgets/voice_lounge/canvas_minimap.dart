import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/canvas_models.dart';
import '../../providers/canvas_provider.dart';

/// Small overview map of the voice-lounge canvas, shown in a corner while in
/// canvas view. It draws every piece of placed content (strokes, images,
/// screen-share windows, dragged avatars) plus the current viewport rectangle,
/// scaled to fit — so the user can see where they are on the otherwise vast
/// 100k×100k surface and tap/drag to jump there (#4, #5).
///
/// The "world" the minimap shows is the union of all content and the current
/// viewport, so the viewport indicator is always visible even when you've
/// panned far into empty space.
class CanvasMinimap extends ConsumerWidget {
  const CanvasMinimap({
    super.key,
    required this.transform,
    required this.viewportSize,
    required this.onRecenter,
    this.width = 168,
    this.height = 116,
  });

  /// Live canvas transform (viewport ← canvas). Drives the viewport rectangle.
  final ValueListenable<Matrix4> transform;

  /// Size of the main canvas viewport in logical pixels.
  final Size viewportSize;

  /// Called with the canvas-space point the user tapped/dragged on the map.
  /// The lounge recenters the main view on it (keeping the current zoom).
  final void Function(Offset canvasPoint) onRecenter;

  final double width;
  final double height;

  static const double _pad = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canvas = ref.watch(canvasProvider);
    return ValueListenableBuilder<Matrix4>(
      valueListenable: transform,
      builder: (context, matrix, _) {
        final viewportRect = _viewportInCanvas(matrix, viewportSize);
        final world = _worldRect(canvas, viewportRect);
        if (world == null) return const SizedBox.shrink();

        final inner = Rect.fromLTWH(
          _pad,
          _pad,
          width - _pad * 2,
          height - _pad * 2,
        );
        final proj = _MinimapProjection.fit(world, inner);

        void recenterFrom(Offset boxPoint) =>
            onRecenter(proj.boxToWorld(boxPoint));

        final scheme = Theme.of(context).colorScheme;
        return GestureDetector(
          onTapDown: (d) => recenterFrom(d.localPosition),
          onPanUpdate: (d) => recenterFrom(d.localPosition),
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: const [
                BoxShadow(blurRadius: 6, color: Color(0x33000000)),
              ],
            ),
            child: CustomPaint(
              painter: _MinimapPainter(
                canvas: canvas,
                viewportRect: viewportRect,
                proj: proj,
                accent: scheme.primary,
                content: scheme.onSurfaceVariant,
                share: scheme.tertiary,
              ),
            ),
          ),
        );
      },
    );
  }

  /// The viewport's footprint in canvas space (unproject the screen corners).
  static Rect _viewportInCanvas(Matrix4 matrix, Size viewport) {
    final inv = Matrix4.copy(matrix)..invert();
    final tl = MatrixUtils.transformPoint(inv, Offset.zero);
    final br = MatrixUtils.transformPoint(
      inv,
      Offset(viewport.width, viewport.height),
    );
    return Rect.fromPoints(tl, br);
  }

  /// Union of all placed content and the viewport, padded 8% so nothing
  /// touches the minimap edge. Returns null only if there is genuinely
  /// nothing finite to show.
  static Rect? _worldRect(CanvasState canvas, Rect viewportRect) {
    Rect? bounds = _finiteRect(viewportRect);
    Rect grow(Rect? acc, Rect r) => acc == null ? r : acc.expandToInclude(r);

    for (final s in canvas.strokes) {
      for (final p in s.points) {
        bounds = grow(bounds, Rect.fromLTWH(p.x, p.y, 0, 0));
      }
    }
    for (final img in canvas.images) {
      bounds = grow(bounds, Rect.fromLTWH(img.x, img.y, img.width, img.height));
    }
    for (final w in canvas.screenSharePositions.values) {
      bounds = grow(bounds, Rect.fromLTWH(w.x, w.y, w.width, w.height));
    }
    for (final a in canvas.avatarPositions.values) {
      bounds = grow(bounds, Rect.fromLTWH(a.x, a.y, 0, 0));
    }
    final result = bounds;
    if (result == null) return null;
    final pad = math.max(result.width, result.height) * 0.08 + 1;
    return result.inflate(pad);
  }

  static Rect? _finiteRect(Rect r) {
    if (!r.left.isFinite ||
        !r.top.isFinite ||
        !r.right.isFinite ||
        !r.bottom.isFinite) {
      return null;
    }
    return r;
  }
}

/// Linear map between canvas-world space and the minimap box.
class _MinimapProjection {
  const _MinimapProjection(this.world, this.fit, this.offset);

  final Rect world;
  final double fit;
  final Offset offset; // box-space position of world.topLeft

  factory _MinimapProjection.fit(Rect world, Rect inner) {
    final w = world.width <= 0 ? 1.0 : world.width;
    final h = world.height <= 0 ? 1.0 : world.height;
    final fit = math.min(inner.width / w, inner.height / h);
    final drawnW = w * fit;
    final drawnH = h * fit;
    final offset = Offset(
      inner.left + (inner.width - drawnW) / 2,
      inner.top + (inner.height - drawnH) / 2,
    );
    return _MinimapProjection(world, fit, offset);
  }

  Offset worldToBox(double x, double y) => Offset(
    offset.dx + (x - world.left) * fit,
    offset.dy + (y - world.top) * fit,
  );

  Rect rectToBox(Rect r) =>
      Rect.fromPoints(worldToBox(r.left, r.top), worldToBox(r.right, r.bottom));

  Offset boxToWorld(Offset b) => Offset(
    (b.dx - offset.dx) / fit + world.left,
    (b.dy - offset.dy) / fit + world.top,
  );
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.canvas,
    required this.viewportRect,
    required this.proj,
    required this.accent,
    required this.content,
    required this.share,
  });

  final CanvasState canvas;
  final Rect viewportRect;
  final _MinimapProjection proj;
  final Color accent;
  final Color content;
  final Color share;

  @override
  void paint(Canvas c, Size size) {
    // Strokes: one faint dot per stroke origin (cheap; conveys spread).
    final strokePaint = Paint()..color = content.withValues(alpha: 0.55);
    for (final s in canvas.strokes) {
      if (s.points.isEmpty) continue;
      final p = proj.worldToBox(s.points.first.x, s.points.first.y);
      c.drawCircle(p, 1.2, strokePaint);
    }

    // Images: small filled rects.
    final imgPaint = Paint()..color = content.withValues(alpha: 0.5);
    for (final img in canvas.images) {
      c.drawRect(
        proj.rectToBox(Rect.fromLTWH(img.x, img.y, img.width, img.height)),
        imgPaint,
      );
    }

    // Screen-share windows: distinct accent rects so they stand out.
    final sharePaint = Paint()..color = share.withValues(alpha: 0.8);
    for (final w in canvas.screenSharePositions.values) {
      c.drawRect(
        proj.rectToBox(Rect.fromLTWH(w.x, w.y, w.width, w.height)),
        sharePaint,
      );
    }

    // Dragged avatars: dots.
    final avatarPaint = Paint()..color = accent.withValues(alpha: 0.9);
    for (final a in canvas.avatarPositions.values) {
      c.drawCircle(proj.worldToBox(a.x, a.y), 2.0, avatarPaint);
    }

    // The current viewport rectangle.
    final viewBox = proj.rectToBox(viewportRect);
    c.drawRect(
      viewBox,
      Paint()
        ..color = accent.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
    c.drawRect(
      viewBox,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_MinimapPainter old) =>
      old.viewportRect != viewportRect ||
      !identical(old.canvas.strokes, canvas.strokes) ||
      !identical(old.canvas.images, canvas.images) ||
      !identical(
        old.canvas.screenSharePositions,
        canvas.screenSharePositions,
      ) ||
      !identical(old.canvas.avatarPositions, canvas.avatarPositions);
}
