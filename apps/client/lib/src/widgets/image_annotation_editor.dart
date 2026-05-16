import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
  /// All completed + the in-progress stroke. The last entry is mutated
  /// in-place while the user is dragging.
  final List<_Stroke> _strokes = <_Stroke>[];

  /// True while a `toImage` rasterisation is running, so the Send button
  /// is debounced.
  bool _exporting = false;

  /// Pinned to the RepaintBoundary so we can grab pixels on Send.
  final GlobalKey _boundaryKey = GlobalKey();

  static const double _strokeWidth = 4.0;

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _strokes.add(_Stroke(<Offset>[details.localPosition]));
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_strokes.isEmpty) return;
    setState(() {
      _strokes.last.points.add(details.localPosition);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    // Strokes are already finalised on each update. Nothing to do here,
    // but keep the hook for future palm-rejection / coalescing logic.
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.clear());
  }

  Future<void> _confirm() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        // No render object — bail without confirming.
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
      if (byteData == null) return;
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
    final hasStrokes = _strokes.isNotEmpty;
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
                // Image fit-to-screen. BoxFit.contain keeps aspect ratio so
                // the user always sees the full image without cropping.
                Positioned.fill(
                  child: Image.memory(
                    widget.imageBytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _StrokesPainter(
                        strokes: _strokes,
                        color: color,
                        strokeWidth: _strokeWidth,
                      ),
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

/// Renders the accumulated [_Stroke] polylines as anti-aliased lines.
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
      final pts = stroke.points;
      if (pts.isEmpty) continue;
      if (pts.length == 1) {
        // Single-tap dot — render as a small filled circle so taps leave
        // a visible mark.
        canvas.drawCircle(
          pts.first,
          strokeWidth / 2,
          Paint()
            ..color = color
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
        continue;
      }
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokesPainter old) {
    return old.strokes != strokes ||
        old.color != color ||
        old.strokeWidth != strokeWidth;
  }
}
