import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// A single stroke drawn on the canvas.
class DrawingStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser;

  DrawingStroke({
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
  });
}

/// An image pinned onto the canvas.
class CanvasImage {
  Offset position;
  Size size;
  final ui.Image image;

  CanvasImage({
    required this.position,
    required this.size,
    required this.image,
  });
}

/// Drawing tool mode.
enum DrawingTool { pen, eraser }

/// Transparent overlay canvas for freehand drawing in the voice lounge.
///
/// Captures pointer events and renders smoothed strokes using quadratic
/// Bezier interpolation.
class LoungeDrawingCanvas extends StatefulWidget {
  final bool isActive;

  const LoungeDrawingCanvas({super.key, required this.isActive});

  @override
  State<LoungeDrawingCanvas> createState() => LoungeDrawingCanvasState();
}

class LoungeDrawingCanvasState extends State<LoungeDrawingCanvas> {
  final List<DrawingStroke> _strokes = [];
  final List<CanvasImage> _images = [];
  DrawingStroke? _currentStroke;

  /// Index of image being dragged, or -1.
  int _draggingIndex = -1;
  Offset _dragStart = Offset.zero;

  DrawingTool _tool = DrawingTool.pen;
  Color _penColor = Colors.white;
  double _penSize = 3.0;
  static const double _eraserSize = 20.0;

  DrawingTool get tool => _tool;
  Color get penColor => _penColor;
  double get penSize => _penSize;

  void setTool(DrawingTool tool) => setState(() => _tool = tool);
  void setPenColor(Color color) => setState(() => _penColor = color);
  void setPenSize(double size) => setState(() => _penSize = size);

  void clearMyDrawings() {
    setState(() {
      _strokes.clear();
      _images.clear();
      _currentStroke = null;
    });
  }

  /// Load image from raw bytes and pin it to the canvas center.
  Future<void> addImageFromBytes(Uint8List bytes) async {
    await _addImageFromBytes(bytes);
  }

  /// Load an image from a URL and pin it to the canvas center.
  Future<void> addImageFromUrl(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await http.get(Uri.parse(url), headers: headers);
      if (response.statusCode != 200) {
        debugPrint(
          '[DrawingCanvas] Image fetch failed: ${response.statusCode}',
        );
        return;
      }
      await _addImageFromBytes(response.bodyBytes);
    } catch (e) {
      debugPrint('[DrawingCanvas] Failed to load image from URL: $e');
    }
  }

  /// Read image data from the system clipboard and pin it to the canvas.
  Future<void> addImageFromClipboard() async {
    try {
      final data = await Clipboard.getData('text/plain');
      // Check if clipboard contains a URL
      final text = data?.text?.trim() ?? '';
      if (text.startsWith('http://') || text.startsWith('https://')) {
        final uri = Uri.tryParse(text);
        if (uri != null) {
          await addImageFromUrl(text);
          return;
        }
      }
    } catch (e) {
      debugPrint('[DrawingCanvas] Clipboard read failed: $e');
    }
  }

  Future<void> _addImageFromBytes(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;

    // Scale to fit within 200px max dimension
    final scale = 200.0 / image.width.toDouble().clamp(1, double.infinity);
    final w = image.width * scale;
    final h = image.height * scale;

    if (!mounted) return;
    final canvasSize = context.size ?? const Size(400, 400);
    setState(() {
      _images.add(
        CanvasImage(
          position: Offset(
            (canvasSize.width - w) / 2,
            (canvasSize.height - h) / 2,
          ),
          size: Size(w, h),
          image: image,
        ),
      );
    });
  }

  /// Check if pointer hits an image (top-most first).
  int _hitTestImage(Offset pos) {
    for (int i = _images.length - 1; i >= 0; i--) {
      final img = _images[i];
      final rect = Rect.fromLTWH(
        img.position.dx,
        img.position.dy,
        img.size.width,
        img.size.height,
      );
      if (rect.contains(pos)) return i;
    }
    return -1;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.isActive) return;
    if (event.buttons != kPrimaryButton) return;

    // Check if tapping on an image (drag to reposition)
    final imgIdx = _hitTestImage(event.localPosition);
    if (imgIdx >= 0) {
      _draggingIndex = imgIdx;
      _dragStart = event.localPosition - _images[imgIdx].position;
      return;
    }

    final stroke = DrawingStroke(
      points: [event.localPosition],
      color: _tool == DrawingTool.eraser ? Colors.transparent : _penColor,
      width: _tool == DrawingTool.eraser ? _eraserSize : _penSize,
      isEraser: _tool == DrawingTool.eraser,
    );
    setState(() => _currentStroke = stroke);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.isActive) return;

    if (_draggingIndex >= 0) {
      setState(() {
        _images[_draggingIndex].position = event.localPosition - _dragStart;
      });
      return;
    }

    if (_currentStroke == null) return;
    setState(() {
      _currentStroke = DrawingStroke(
        points: [..._currentStroke!.points, event.localPosition],
        color: _currentStroke!.color,
        width: _currentStroke!.width,
        isEraser: _currentStroke!.isEraser,
      );
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_draggingIndex >= 0) {
      _draggingIndex = -1;
      return;
    }
    if (_currentStroke == null) return;
    setState(() {
      _strokes.add(_currentStroke!);
      _currentStroke = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasContent =
        _strokes.isNotEmpty || _currentStroke != null || _images.isNotEmpty;

    // Always render strokes/images; only capture pointer events when active.
    if (!widget.isActive && !hasContent) return const SizedBox.shrink();

    final painter = RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _DrawingPainter(
          strokes: _strokes,
          currentStroke: _currentStroke,
          images: _images,
        ),
      ),
    );

    if (!widget.isActive) {
      return IgnorePointer(child: painter);
    }

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      behavior: HitTestBehavior.translucent,
      child: painter,
    );
  }
}

class _DrawingPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final DrawingStroke? currentStroke;
  final List<CanvasImage> images;

  _DrawingPainter({
    required this.strokes,
    this.currentStroke,
    this.images = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    // saveLayer so BlendMode.clear (eraser) works on the stroke layer
    canvas.saveLayer(Offset.zero & size, Paint());

    // Draw pinned images first (below strokes)
    for (final img in images) {
      final dst = Rect.fromLTWH(
        img.position.dx,
        img.position.dy,
        img.size.width,
        img.size.height,
      );
      final src = Rect.fromLTWH(
        0,
        0,
        img.image.width.toDouble(),
        img.image.height.toDouble(),
      );
      canvas.drawImageRect(img.image, src, dst, Paint());
    }

    for (final stroke in strokes) {
      _drawStroke(canvas, stroke);
    }
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!);
    }

    canvas.restore();
  }

  void _drawStroke(Canvas canvas, DrawingStroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke.width
      ..style = PaintingStyle.stroke;

    if (stroke.isEraser) {
      // BlendMode.clear punches out alpha; the color value doesn't affect the
      // result, but an explicit fully-transparent color avoids a warning on
      // some Flutter build configurations where a missing color may fall back
      // to opaque black and render unexpectedly on non-isolated layers.
      paint
        ..blendMode = ui.BlendMode.clear
        ..color = const Color(0x00000000);
    } else {
      paint.color = stroke.color;
    }

    final pts = stroke.points;

    // Single-point tap: draw a dot.
    if (pts.length == 1) {
      canvas.drawCircle(
        pts[0],
        stroke.width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }

    // Build a smoothed path using quadratic Bezier curves
    final path = ui.Path();

    path.moveTo(pts[0].dx, pts[0].dy);

    if (pts.length == 2) {
      path.lineTo(pts[1].dx, pts[1].dy);
    } else {
      // Use midpoints as control anchors for smooth curves
      for (int i = 1; i < pts.length - 1; i++) {
        final mid = Offset(
          (pts[i].dx + pts[i + 1].dx) / 2,
          (pts[i].dy + pts[i + 1].dy) / 2,
        );
        path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
      }
      // Final segment
      final last = pts.last;
      path.lineTo(last.dx, last.dy);
    }

    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _DrawingPainter oldDelegate) =>
      strokes.length != oldDelegate.strokes.length ||
      currentStroke != oldDelegate.currentStroke ||
      images.length != oldDelegate.images.length;
}
