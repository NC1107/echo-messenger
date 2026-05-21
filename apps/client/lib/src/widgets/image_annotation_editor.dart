import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/toast_service.dart';

/// Fullscreen image annotation editor (MVP for #908).
///
/// Lets the user free-hand draw on top of an image with a single primary
/// color and a fixed stroke width before sending. Undo and Clear are
/// supported. On Send the image plus strokes are rasterised to PNG via
/// [RepaintBoundary.toImage] and handed back through [onConfirm].
///
/// MVP scope: pen-only, single colour, fixed stroke width 4.0. No text
/// overlay, no shapes, no layers, no colour picker. Those are deferred.
class ImageAnnotationEditor extends StatefulWidget {
  /// Raw bytes of the source image (PNG/JPEG/etc — anything Flutter's
  /// `Image.memory` can decode).
  final Uint8List imageBytes;

  /// Called with the rasterised PNG bytes when the user taps Send.
  final void Function(Uint8List annotatedPngBytes) onConfirm;

  const ImageAnnotationEditor({
    super.key,
    required this.imageBytes,
    required this.onConfirm,
  });

  @override
  State<ImageAnnotationEditor> createState() => _ImageAnnotationEditorState();
}

/// A single accumulated stroke — a polyline of pointer positions in the
/// local coordinate space of the [RepaintBoundary].
class _Stroke {
  final List<Offset> points;
  const _Stroke(this.points);
}

class _ImageAnnotationEditorState extends State<ImageAnnotationEditor> {
  /// Completed strokes. Only mutated (via setState) on pan-start and pan-end,
  /// not on every pan-update frame.
  final List<_Stroke> _committedStrokes = <_Stroke>[];

  /// Points of the stroke currently being drawn. Updated at 60Hz during a
  /// pan gesture; drives a [ValueListenableBuilder] so only the live-stroke
  /// layer repaints instead of the whole scaffold.
  final ValueNotifier<List<Offset>?> _livePoints = ValueNotifier<List<Offset>?>(
    null,
  );

  /// True while a `toImage` rasterisation is running, so the Send button
  /// is debounced.
  bool _exporting = false;

  /// Pinned to the outer RepaintBoundary so we can grab pixels on Send.
  final GlobalKey _boundaryKey = GlobalKey();

  /// Stable image provider created once in [initState] so [Image] does not
  /// re-decode the bytes on every rebuild.
  late final ImageProvider _imageProvider;

  static const double _strokeWidth = 4.0;

  @override
  void initState() {
    super.initState();
    _imageProvider = MemoryImage(widget.imageBytes);
  }

  @override
  void dispose() {
    _livePoints.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    // Start a new live stroke. This setState is cheap — it only updates
    // the toolbar button enabled-state via hasStrokes.
    _livePoints.value = <Offset>[details.localPosition];
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final live = _livePoints.value;
    if (live == null) return;
    // Mutate a fresh list so ValueNotifier listeners see the change.
    _livePoints.value = List<Offset>.of(live)..add(details.localPosition);
  }

  void _onPanEnd(DragEndDetails details) {
    final live = _livePoints.value;
    if (live == null || live.isEmpty) return;
    // Commit the finished stroke and clear the live notifier.
    setState(() {
      _committedStrokes.add(_Stroke(live));
      _livePoints.value = null;
    });
  }

  void _undo() {
    if (_committedStrokes.isEmpty) return;
    setState(() => _committedStrokes.removeLast());
  }

  void _clear() {
    if (_committedStrokes.isEmpty) return;
    setState(() => _committedStrokes.clear());
  }

  Future<void> _confirm() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) {
          ToastService.show(
            context,
            'Failed to export image. Try a smaller image or close other apps.',
            type: ToastType.error,
          );
        }
        return;
      }
      // Match device pixel ratio so the exported image has the same
      // resolution the user is seeing on screen.
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final ui.Image image = await boundary.toImage(pixelRatio: dpr);
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      if (byteData == null) {
        if (mounted) {
          ToastService.show(
            context,
            'Failed to export image. Try a smaller image or close other apps.',
            type: ToastType.error,
          );
        }
        return;
      }
      final Uint8List pngBytes = byteData.buffer.asUint8List();
      if (!mounted) return;
      widget.onConfirm(pngBytes);
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    // hasStrokes is derived only from committed strokes because the live
    // stroke is tracked separately via ValueNotifier.
    final hasStrokes = _committedStrokes.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Annotate'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: hasStrokes ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: hasStrokes ? _clear : null,
          ),
          IconButton(
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.send),
            tooltip: 'Send',
            onPressed: _exporting ? null : _confirm,
          ),
        ],
      ),
      body: SizedBox.expand(
        // Outer RepaintBoundary is keyed so _confirm can capture all layers.
        child: RepaintBoundary(
          key: _boundaryKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Image: uses a stable MemoryImage provider (created once in
                // initState) so the codec is not re-instantiated on rebuilds.
                Positioned.fill(
                  child: Image(
                    image: _imageProvider,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
                // Committed strokes — wrapped in a RepaintBoundary so Flutter
                // can cache the rasterised layer between pan frames.
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _StrokesPainter(
                          strokes: _committedStrokes,
                          color: color,
                          strokeWidth: _strokeWidth,
                        ),
                      ),
                    ),
                  ),
                ),
                // Live stroke — repaints on every pan frame without touching
                // the committed-strokes layer or the image.
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<List<Offset>?>(
                      valueListenable: _livePoints,
                      builder: (context, points, _) {
                        return CustomPaint(
                          painter: _LiveStrokePainter(
                            points: points,
                            color: color,
                            strokeWidth: _strokeWidth,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders the accumulated committed [_Stroke] polylines as anti-aliased lines.
class _StrokesPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final Color color;
  final double strokeWidth;

  const _StrokesPainter({
    required this.strokes,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    for (final stroke in strokes) {
      _paintPoints(canvas, stroke.points, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokesPainter old) {
    return old.strokes != strokes ||
        old.color != color ||
        old.strokeWidth != strokeWidth;
  }
}

/// Renders the single in-progress stroke during a pan gesture.
///
/// Separated from [_StrokesPainter] so the [ValueListenableBuilder] driving
/// this layer does not trigger repaints on the committed-strokes layer.
class _LiveStrokePainter extends CustomPainter {
  final List<Offset>? points;
  final Color color;
  final double strokeWidth;

  const _LiveStrokePainter({
    required this.points,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pts = points;
    if (pts == null || pts.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    _paintPoints(canvas, pts, paint);
  }

  @override
  bool shouldRepaint(covariant _LiveStrokePainter old) {
    return old.points != points ||
        old.color != color ||
        old.strokeWidth != strokeWidth;
  }
}

/// Shared drawing logic for a list of [Offset] points.
void _paintPoints(Canvas canvas, List<Offset> pts, Paint paint) {
  if (pts.isEmpty) return;
  if (pts.length == 1) {
    // Single-tap dot — render as a small filled circle so taps leave
    // a visible mark.
    canvas.drawCircle(
      pts.first,
      paint.strokeWidth / 2,
      Paint()
        ..color = paint.color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    return;
  }
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length; i++) {
    path.lineTo(pts[i].dx, pts[i].dy);
  }
  canvas.drawPath(path, paint);
}
