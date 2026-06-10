import 'dart:ui' as ui show Color;

import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import '../../models/canvas_models.dart';
import '../../services/canvas_perf.dart';

// ---------------------------------------------------------------------------
// Active stroke snapshot
// ---------------------------------------------------------------------------

/// Immutable snapshot of the user's in-flight stroke. Held by
/// [ActiveStrokeNotifier] and consumed by [_ActiveStrokePainter] each tick.
///
/// Wire format stays raw [CanvasPoint]s -- the smoothing pipeline runs
/// purely local, so encryption / WS sync / multi-device authority are
/// unaffected (see docs/voice-lounge/05-canvas-rewrite-spec.md §B.3).
@immutable
class ActiveStroke {
  /// The kind being drawn. Drives painter branching (eraser blend, shape
  /// straight-line, freehand outline polygon).
  final StrokeKind kind;

  /// Active colour. CSS hex (e.g. `#FF5500`); for eraser strokes this is
  /// ignored at paint time -- BlendMode.dstOut clears underneath instead.
  final String color;

  /// Active width in canvas-space logical pixels. The eraser-specific 3×
  /// inflation is applied by the caller (matching canvas_provider's
  /// behaviour); the painter treats this as the raw `size` for
  /// perfect_freehand.
  final double width;

  /// Points accumulated since the last `start()` call, in absolute
  /// canvas-space pixels.
  final List<CanvasPoint> points;

  const ActiveStroke({
    required this.kind,
    required this.color,
    required this.width,
    required this.points,
  });
}

/// Bypasses Riverpod's `state = state.copyWith(activePoints: ...)` hot path
/// for the local in-flight stroke. Each pointer-move calls [addPoint], which
/// notifies the in-flight `CustomPaint` only -- background + committed-
/// strokes layers (under their own `RepaintBoundary`s) do not rebuild.
///
/// One notifier per local user. Remote partial strokes still flow through
/// canvas_provider's `state.strokes` (id prefix `partial_<userId>_in_progress`)
/// because remote ticks arrive at the WS broadcast rate (~30 Hz) and the
/// perf bug is specifically the *local* per-pointer-move rebuild storm.
/// See docs/voice-lounge/05-canvas-rewrite-spec.md §B.2.
class ActiveStrokeNotifier extends ChangeNotifier {
  final List<CanvasPoint> _points = <CanvasPoint>[];
  StrokeKind _kind = StrokeKind.pen;
  String _color = '#FFFFFF';
  double _width = 3.0;
  bool _active = false;

  /// Whether a stroke is currently being drawn.
  bool get isActive => _active;

  /// Number of points in the in-flight stroke. Exposed for the lounge's
  /// optional on-canvas debug overlay (user feedback 2026-05-29 on
  /// canvas rewrite live test, bug 5).
  int get pointCount => _points.length;

  /// Read-only snapshot of the current in-flight stroke, or `null` if no
  /// stroke is in progress. Painter consumes this each tick.
  ActiveStroke? get current => _active
      ? ActiveStroke(
          kind: _kind,
          color: _color,
          width: _width,
          points: List<CanvasPoint>.unmodifiable(_points),
        )
      : null;

  /// Begin a new stroke. Replaces any in-flight state -- callers are
  /// expected to call [end] or [cancel] on the previous stroke first; this
  /// is defensive so a missed `end` can't strand the previous points.
  void start({
    required StrokeKind kind,
    required String color,
    required double width,
    required CanvasPoint first,
  }) {
    _points
      ..clear()
      ..add(first);
    _kind = kind;
    _color = color;
    _width = width;
    _active = true;
    notifyListeners();
  }

  /// Append a point to the in-flight stroke. For shape kinds (line / rect /
  /// ellipse) the trailing point is replaced rather than appended so the
  /// shape rubberbands rather than growing a polyline tail.
  void addPoint(CanvasPoint p) {
    if (!_active) return;
    if (isShapeKind(_kind) && _points.isNotEmpty) {
      if (_points.length == 1) {
        _points.add(p);
      } else {
        _points[_points.length - 1] = p;
      }
    } else {
      _points.add(p);
    }
    notifyListeners();
  }

  /// Commit the stroke. Clears local state -- the committed payload is sent
  /// via canvas_provider's `endStroke()` in the same gesture path.
  void end() => _clear();

  /// Cancel the stroke (e.g. a second pointer arrived mid-draw, or the user
  /// tapped Esc). Clears state without committing.
  void cancel() => _clear();

  void _clear() {
    if (!_active && _points.isEmpty) return;
    _points.clear();
    _active = false;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Three-layer painter widget
// ---------------------------------------------------------------------------

/// Background + committed-strokes + in-flight-stroke, each wrapped in a
/// dedicated [RepaintBoundary] so a mid-stroke tick only repaints the short
/// in-flight polyline -- not the full set of prior strokes, not the
/// background mesh.
///
/// The widget is intentionally narrow: it owns drawing-layer rendering and
/// nothing else. Avatars, images, and screen-share windows continue to live
/// in `voice_canvas.dart` as siblings under the lounge screen's `Stack`.
class LoungeCanvasStrokes extends StatelessWidget {
  /// Strokes already committed to the canvas (server-snapshot + WS
  /// `stroke` events + remote `stroke_partial` placeholders -- the partial
  /// placeholders live in `canvas_provider.state.strokes` and continue to
  /// rebuild this layer when a remote user is drawing, which is fine: that
  /// path is not the local hot path the rewrite targets).
  final List<CanvasStroke> committedStrokes;

  /// The local user's in-flight stroke notifier. Pointer-move ticks fed
  /// into this notifier rebuild only the in-flight layer.
  final ActiveStrokeNotifier activeStroke;

  /// The background widget (vertex mesh / theme image). Sits under its own
  /// `RepaintBoundary` so settings changes (theme toggle, mesh density)
  /// don't blow the cache for the committed-strokes raster.
  final Widget background;

  const LoungeCanvasStrokes({
    super.key,
    required this.committedStrokes,
    required this.activeStroke,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        RepaintBoundary(child: background),
        RepaintBoundary(
          child: CustomPaint(
            painter: _CommittedStrokesPainter(strokes: committedStrokes),
            child: const SizedBox.expand(),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: _ActiveStrokePainter(notifier: activeStroke),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Painters
// ---------------------------------------------------------------------------

class _CommittedStrokesPainter extends CustomPainter {
  final List<CanvasStroke> strokes;

  const _CommittedStrokesPainter({required this.strokes});

  bool _hasEraser() {
    for (final s in strokes) {
      if (s.kind == StrokeKind.eraser) return true;
    }
    return false;
  }

  @override
  void paint(Canvas c, Size size) {
    final sw = Stopwatch()..start();
    final needsLayer = _hasEraser();
    if (needsLayer) c.saveLayer(Offset.zero & size, Paint());
    for (final stroke in strokes) {
      paintStroke(c, size, stroke);
    }
    if (needsLayer) c.restore();
    sw.stop();
    CanvasPerf.recordPaintMs(sw.elapsedMicroseconds / 1000.0);
  }

  @override
  bool shouldRepaint(_CommittedStrokesPainter old) {
    // VL-18: repaint whenever the strokes list instance changes. The list is
    // passed straight from watched `canvas.strokes`, and canvas_provider
    // replaces it (a fresh List) on every mutation — add, remove, undo, or an
    // in-place stroke/partial edit. The previous last-element-only heuristic
    // missed mid-list mutations (undo to the same length, a non-last remote
    // edit, or a colour/width change to the trailing stroke) and rendered
    // stale. Identity compare is correct AND cheap: the list isn't rebuilt
    // per-frame, so this can't trigger a repaint storm.
    return !identical(old.strokes, strokes);
  }
}

class _ActiveStrokePainter extends CustomPainter {
  final ActiveStrokeNotifier notifier;

  _ActiveStrokePainter({required this.notifier}) : super(repaint: notifier);

  @override
  void paint(Canvas c, Size size) {
    final stroke = notifier.current;
    if (stroke == null || stroke.points.isEmpty) return;
    final sw = Stopwatch()..start();
    // Wrap eraser in a save-layer so BlendMode.dstOut composites against
    // the in-flight layer's own raster; the committed-strokes layer is
    // already rasterised below us and would otherwise be the target.
    final needsLayer = stroke.kind == StrokeKind.eraser;
    if (needsLayer) c.saveLayer(Offset.zero & size, Paint());
    paintActiveStroke(c, size, stroke);
    if (needsLayer) c.restore();
    sw.stop();
    CanvasPerf.recordPaintMs(sw.elapsedMicroseconds / 1000.0);
  }

  @override
  bool shouldRepaint(_ActiveStrokePainter old) =>
      !identical(old.notifier, notifier);
}

// ---------------------------------------------------------------------------
// Stroke geometry resolution (public for tests)
// ---------------------------------------------------------------------------

/// Renders a [CanvasStroke] onto [c]. Public so widget tests can record
/// draw calls against a mock canvas without instantiating a painter.
@visibleForTesting
void paintStroke(Canvas c, Size size, CanvasStroke stroke) {
  if (stroke.points.isEmpty) return;
  if (stroke.kind == StrokeKind.text) {
    _paintText(c, size, stroke);
    return;
  }
  final paint = _resolvePaint(stroke);
  if (stroke.points.length == 1 && !isShapeKind(stroke.kind)) {
    final p = stroke.points.first;
    c.drawCircle(
      Offset(p.x, p.y),
      stroke.width / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }
  if (isShapeKind(stroke.kind) && stroke.points.length >= 2) {
    _paintShape(c, stroke, paint);
    return;
  }
  // Freehand (pen / highlighter / eraser): pipe through perfect_freehand
  // to get a tapered, velocity-thinned outline polygon; fill the polygon.
  // VL-1d: the smoothed outline + filled Path are memoised per stroke instance
  // (see [committedStrokePath]). Re-running getStroke() over every committed
  // stroke each frame is exactly what turned a single remote partial tick into
  // an O(strokes × points) re-tessellation storm — a remote peer drawing flips
  // canvas.strokes to a fresh list ~30×/s, repainting this layer, and only the
  // one mutated partial stroke actually changed. The cache keeps every static
  // stroke's paint cost at a single drawPath.
  final path = committedStrokePath(stroke);
  if (path == null) return;
  c.drawPath(path, paint..style = PaintingStyle.fill);
}

/// Cache entry slot: an [Expando] cannot store `null` to mean "computed and
/// empty", so we wrap the (possibly-null) Path. A missing expando entry is a
/// cold miss; a present entry with a null [path] is a memoised empty outline.
@immutable
class _CachedOutline {
  final Path? path;
  const _CachedOutline(this.path);
}

/// Per-stroke memoised outline cache, keyed on [CanvasStroke] **instance
/// identity**. [CanvasStroke] is immutable, so a new instance is produced only
/// when geometry actually changes (a remote partial's `copyWith` append, a
/// colour/width edit, undo/redo rebuilding the list). Static committed strokes
/// keep the same instance frame-to-frame, so they hit the cache and skip the
/// perfect_freehand tessellation entirely. [Expando] auto-evicts when a stroke
/// is garbage-collected (undo / clear / 2000-stroke cap), so no manual reaping.
final Expando<_CachedOutline> _committedOutlineCache = Expando<_CachedOutline>(
  'committedStrokeOutline',
);

/// Returns the memoised filled-outline [Path] for a committed freehand
/// [stroke], computing it lazily on first paint and reusing it on every
/// subsequent frame where the same stroke instance is rendered. Returns `null`
/// when perfect_freehand yields an empty outline (degenerate input) — callers
/// skip the draw in that case. Public for tests.
@visibleForTesting
Path? committedStrokePath(CanvasStroke stroke) {
  final cached = _committedOutlineCache[stroke];
  if (cached != null) return cached.path;
  final outline = _freehandOutline(stroke, isComplete: true);
  final path = outline.isEmpty ? null : _outlineToPath(outline);
  _committedOutlineCache[stroke] = _CachedOutline(path);
  return path;
}

/// Same as [paintStroke] but for the in-flight stroke: passes
/// `isComplete: false` to perfect_freehand so the trailing end is drawn
/// slightly behind the last sampled point (matches the live preview
/// behaviour of tldraw / Excalidraw).
@visibleForTesting
void paintActiveStroke(Canvas c, Size size, ActiveStroke stroke) {
  if (stroke.points.isEmpty) return;
  final wireStroke = CanvasStroke(
    id: '__active__',
    color: stroke.color,
    width: stroke.width,
    points: stroke.points,
    kind: stroke.kind,
  );
  if (stroke.kind == StrokeKind.text) return; // text uses tap-to-place
  final paint = _resolvePaint(wireStroke);
  if (stroke.points.length == 1 && !isShapeKind(stroke.kind)) {
    final p = stroke.points.first;
    c.drawCircle(
      Offset(p.x, p.y),
      stroke.width / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }
  if (isShapeKind(stroke.kind) && stroke.points.length >= 2) {
    _paintShape(c, wireStroke, paint);
    return;
  }
  final outline = _freehandOutline(wireStroke, isComplete: false);
  if (outline.isEmpty) return;
  c.drawPath(_outlineToPath(outline), paint..style = PaintingStyle.fill);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

Paint _resolvePaint(CanvasStroke stroke) {
  final paint = Paint()
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  switch (stroke.kind) {
    case StrokeKind.eraser:
      paint
        ..blendMode = BlendMode.dstOut
        ..color = const Color(0xFF000000);
      break;
    case StrokeKind.highlighter:
      paint
        ..blendMode = BlendMode.srcOver
        ..color = _parseColor(stroke.color).withValues(alpha: 0.35);
      break;
    case StrokeKind.pen:
    case StrokeKind.line:
    case StrokeKind.rect:
    case StrokeKind.ellipse:
    case StrokeKind.text:
      paint
        ..blendMode = BlendMode.srcOver
        ..color = _parseColor(stroke.color);
      break;
  }
  return paint;
}

void _paintShape(Canvas c, CanvasStroke stroke, Paint paint) {
  final first = stroke.points.first;
  final last = stroke.points.last;
  final p1 = Offset(first.x, first.y);
  final p2 = Offset(last.x, last.y);
  paint
    ..style = PaintingStyle.stroke
    ..strokeWidth = stroke.width;
  switch (stroke.kind) {
    case StrokeKind.line:
      c.drawLine(p1, p2, paint);
      break;
    case StrokeKind.rect:
      c.drawRect(Rect.fromPoints(p1, p2), paint);
      break;
    case StrokeKind.ellipse:
      c.drawOval(Rect.fromPoints(p1, p2), paint);
      break;
    case StrokeKind.pen:
    case StrokeKind.eraser:
    case StrokeKind.highlighter:
    case StrokeKind.text:
      // Non-shape kinds never call this helper; defensive no-op.
      break;
  }
}

void _paintText(Canvas c, Size size, CanvasStroke stroke) {
  final label = stroke.text;
  if (label == null || label.isEmpty) return;
  final anchor = stroke.points.first;
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: _parseColor(stroke.color),
        fontSize: stroke.width,
        fontWeight: FontWeight.w500,
        shadows: const <Shadow>[
          Shadow(color: Color(0xAA000000), blurRadius: 2),
        ],
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.left,
  )..layout(maxWidth: size.width);
  tp.paint(c, Offset(anchor.x, anchor.y));
}

List<Offset> _freehandOutline(CanvasStroke stroke, {required bool isComplete}) {
  final input = <PointVector>[
    for (final p in stroke.points) PointVector(p.x, p.y),
  ];
  // Highlighter strokes get no taper / no thinning so a back-pass overlaps
  // the first pass at the same width (matches the real-marker feel).
  final isMarker = stroke.kind == StrokeKind.highlighter;
  final options = StrokeOptions(
    size: stroke.width,
    thinning: isMarker ? 0.0 : 0.5,
    smoothing: 0.5,
    streamline: 0.5,
    simulatePressure: !isMarker,
    start: StrokeEndOptions.start(taperEnabled: false),
    end: StrokeEndOptions.end(taperEnabled: false),
    isComplete: isComplete,
  );
  return getStroke(input, options: options);
}

Path _outlineToPath(List<Offset> outline) {
  final path = Path();
  if (outline.isEmpty) return path;
  path.moveTo(outline.first.dx, outline.first.dy);
  for (int i = 1; i < outline.length; i++) {
    final p = outline[i];
    path.lineTo(p.dx, p.dy);
  }
  path.close();
  return path;
}

ui.Color _parseColor(String hex) {
  // VL-1: this runs inside CustomPainter.paint() on every stroke, including
  // strokes authored by remote peers. A non-hex colour string (a future
  // client, a CSS name, corruption) would make int.parse throw *inside*
  // paint(), corrupting the frame for everyone. tryParse + fallback instead.
  final s = hex.replaceFirst('#', '');
  if (s.length == 8) {
    final v = int.tryParse(s, radix: 16);
    if (v != null) return ui.Color(v);
  } else if (s.length == 6) {
    final v = int.tryParse(s, radix: 16);
    if (v != null) return ui.Color(0xFF000000 | v);
  }
  return const ui.Color(0xFFFFFFFF);
}
