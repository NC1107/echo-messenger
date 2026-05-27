import 'dart:ui' show Color;

// ---------------------------------------------------------------------------
// Canvas geometry helpers
// ---------------------------------------------------------------------------

/// Fixed virtual canvas size shared by every participant regardless of their
/// screen size or orientation. The InteractiveViewer in the voice lounge
/// scrolls + zooms inside this 4096×4096 logical surface so a circle drawn
/// on a phone reads as a circle on a desktop. See
/// `apps/client/lib/src/screens/voice_lounge_screen.dart` for the
/// viewport-fit math (minScale = min(viewportW, viewportH) / kCanvasWidth).
const double kCanvasWidth = 4096;
const double kCanvasHeight = 4096;

/// Migrates legacy [0, 1] normalized coordinates persisted before the fixed
/// 4096-px space landed. The heuristic is "value ≤ 1.0 means legacy
/// normalized" — safe because the new pixel range starts at 0 and crosses 1
/// instantly (4096 / 4096 ≈ 1.0 is at the bottom-right corner; any other
/// real-world stroke point is far above 1.0). Without this old persisted
/// canvases would collapse into the top-left pixel after upgrade.
double _migrateLegacyCoord(double value, double axisExtent) {
  if (value <= 1.0) return value * axisExtent;
  return value;
}

/// A 2-D point in absolute pixels within the fixed [kCanvasWidth] ×
/// [kCanvasHeight] virtual canvas. Storing absolute coordinates (instead of
/// the legacy 0..1 normalized scheme) means a stroke drawn on a 420×900
/// phone lays down the same circle a 1920×1080 desktop sees, because every
/// participant shares the same 4096-px coordinate space — only the viewport
/// (zoom + pan) differs.
class CanvasPoint {
  final double x;
  final double y;

  const CanvasPoint({required this.x, required this.y});

  factory CanvasPoint.fromJson(Map<String, dynamic> json) => CanvasPoint(
    x: _migrateLegacyCoord((json['x'] as num).toDouble(), kCanvasWidth),
    y: _migrateLegacyCoord((json['y'] as num).toDouble(), kCanvasHeight),
  );

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  @override
  String toString() => 'CanvasPoint($x, $y)';

  // Value equality is load-bearing for the voice lounge: every audio
  // poll (100ms) rebuilds CanvasState.avatarPositions with fresh
  // CanvasPoint instances, and downstream widgets `select` on them.
  // Without ==/hashCode every selector fires every tick, dragging the
  // whole tree into a 10Hz rebuild storm in CanvasKit / web.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CanvasPoint && x == other.x && y == other.y);

  @override
  int get hashCode => Object.hash(x, y);
}

// ---------------------------------------------------------------------------
// Drawing strokes
// ---------------------------------------------------------------------------

/// Brush type. `pen` and `eraser` are the original freehand modes;
/// `highlighter` is a thick translucent pen; `line`, `rect`, `ellipse`
/// are two-point shapes recorded as `[first, last]` and rendered as
/// straight geometry by the painter. `text` is a single-anchor text label;
/// `points[0]` is the top-left anchor, `width` is the font size in
/// logical pixels, and the optional `text` field on [CanvasStroke] holds
/// the label content.
enum StrokeKind { pen, eraser, highlighter, line, rect, ellipse, text }

/// `true` if the kind is a two-point geometric shape rather than a freehand
/// stroke. Shape kinds always store exactly two points: the gesture's start
/// and end positions; intermediate samples are discarded.
bool isShapeKind(StrokeKind kind) =>
    kind == StrokeKind.line ||
    kind == StrokeKind.rect ||
    kind == StrokeKind.ellipse;

StrokeKind _strokeKindFromString(String? raw) {
  switch (raw) {
    case 'eraser':
      return StrokeKind.eraser;
    case 'highlighter':
      return StrokeKind.highlighter;
    case 'line':
      return StrokeKind.line;
    case 'rect':
      return StrokeKind.rect;
    case 'ellipse':
      return StrokeKind.ellipse;
    case 'text':
      return StrokeKind.text;
    case 'pen':
    default:
      return StrokeKind.pen;
  }
}

String _strokeKindToString(StrokeKind kind) {
  switch (kind) {
    case StrokeKind.eraser:
      return 'eraser';
    case StrokeKind.highlighter:
      return 'highlighter';
    case StrokeKind.line:
      return 'line';
    case StrokeKind.rect:
      return 'rect';
    case StrokeKind.ellipse:
      return 'ellipse';
    case StrokeKind.text:
      return 'text';
    case StrokeKind.pen:
      return 'pen';
  }
}

/// A single freehand stroke drawn on the canvas.
class CanvasStroke {
  final String id;
  final String color; // CSS hex color, e.g. "#FF5500" or "#00000000" for eraser
  final double width; // brush width in logical pixels (before normalization)
  final List<CanvasPoint> points;
  final StrokeKind kind;

  /// Only set for `kind == StrokeKind.text`; otherwise `null`. Stored on the
  /// stroke so text labels round-trip through the existing strokes JSONB
  /// without needing a new server-side column.
  final String? text;

  const CanvasStroke({
    required this.id,
    required this.color,
    required this.width,
    required this.points,
    this.kind = StrokeKind.pen,
    this.text,
  });

  factory CanvasStroke.fromJson(Map<String, dynamic> json) => CanvasStroke(
    id: json['id'] as String,
    color: json['color'] as String,
    width: (json['width'] as num).toDouble(),
    points: (json['points'] as List)
        .map((p) => CanvasPoint.fromJson(p as Map<String, dynamic>))
        .toList(),
    kind: _strokeKindFromString(json['kind'] as String?),
    text: json['text'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'color': color,
    'width': width,
    'points': points.map((p) => p.toJson()).toList(),
    'kind': _strokeKindToString(kind),
    if (text != null) 'text': text,
  };

  CanvasStroke copyWith({
    String? id,
    String? color,
    double? width,
    List<CanvasPoint>? points,
    StrokeKind? kind,
    String? text,
  }) => CanvasStroke(
    id: id ?? this.id,
    color: color ?? this.color,
    width: width ?? this.width,
    points: points ?? this.points,
    kind: kind ?? this.kind,
    text: text ?? this.text,
  );
}

// ---------------------------------------------------------------------------
// Canvas images
// ---------------------------------------------------------------------------

/// An image pinned to the canvas (pasted from clipboard or drag-dropped).
///
/// All coordinates and dimensions are absolute pixels inside the
/// [kCanvasWidth] × [kCanvasHeight] virtual canvas. Legacy 0..1 values
/// persisted before the fixed-size canvas migration are auto-rescaled in
/// [CanvasImage.fromJson].
class CanvasImage {
  final String id;
  final String url; // absolute URL served via /api/media/{id}
  final double x; // pixel left edge in the 4096-px space
  final double y; // pixel top edge in the 4096-px space
  final double width; // pixel width in the 4096-px space
  final double height; // pixel height in the 4096-px space

  const CanvasImage({
    required this.id,
    required this.url,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory CanvasImage.fromJson(Map<String, dynamic> json) => CanvasImage(
    id: json['id'] as String,
    url: json['url'] as String,
    x: _migrateLegacyCoord((json['x'] as num).toDouble(), kCanvasWidth),
    y: _migrateLegacyCoord((json['y'] as num).toDouble(), kCanvasHeight),
    width: _migrateLegacyCoord((json['width'] as num).toDouble(), kCanvasWidth),
    height: _migrateLegacyCoord(
      (json['height'] as num).toDouble(),
      kCanvasHeight,
    ),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  CanvasImage copyWith({double? x, double? y, double? width, double? height}) =>
      CanvasImage(
        id: id,
        url: url,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
      );
}

// ---------------------------------------------------------------------------
// Avatar positions
// ---------------------------------------------------------------------------

/// A participant's current position on the canvas.
///
/// Coordinates are absolute pixels in the [kCanvasWidth] × [kCanvasHeight]
/// virtual space. The local user's own position is tracked separately and
/// broadcast via WebSocket on drag-end.
class AvatarPosition {
  final String userId;
  final double x;
  final double y;

  /// Scale factor applied to the rendered avatar / video tile. 1.0 = the
  /// historical default size; bounded by [minScale] / [maxScale] in the
  /// canvas controller. Broadcast over the same `avatar_move` WS event so
  /// the server does not need a new event kind.
  final double scale;

  static const double minScale = 0.5;
  static const double maxScale = 5.0;

  const AvatarPosition({
    required this.userId,
    required this.x,
    required this.y,
    this.scale = 1.0,
  });

  AvatarPosition copyWith({double? x, double? y, double? scale}) =>
      AvatarPosition(
        userId: userId,
        x: x ?? this.x,
        y: y ?? this.y,
        scale: scale ?? this.scale,
      );
}

// ---------------------------------------------------------------------------
// Drawing tools
// ---------------------------------------------------------------------------

enum CanvasTool { none, pen, eraser, highlighter, line, rect, ellipse, text }

/// `true` for any tool that records a freehand or shape stroke (i.e. the
/// drawing-layer should grab pointer events for it). Text is excluded —
/// it uses a tap-to-place flow handled separately in the canvas widget.
bool isDrawingTool(CanvasTool tool) =>
    tool == CanvasTool.pen ||
    tool == CanvasTool.eraser ||
    tool == CanvasTool.highlighter ||
    tool == CanvasTool.line ||
    tool == CanvasTool.rect ||
    tool == CanvasTool.ellipse;

/// Map the currently-selected [CanvasTool] to the [StrokeKind] it produces.
StrokeKind strokeKindForTool(CanvasTool tool) {
  switch (tool) {
    case CanvasTool.eraser:
      return StrokeKind.eraser;
    case CanvasTool.highlighter:
      return StrokeKind.highlighter;
    case CanvasTool.line:
      return StrokeKind.line;
    case CanvasTool.rect:
      return StrokeKind.rect;
    case CanvasTool.ellipse:
      return StrokeKind.ellipse;
    case CanvasTool.text:
      return StrokeKind.text;
    case CanvasTool.pen:
    case CanvasTool.none:
      return StrokeKind.pen;
  }
}

// ---------------------------------------------------------------------------
// Full canvas state
// ---------------------------------------------------------------------------

/// Immutable snapshot of the shared voice-lounge canvas state.
class CanvasState {
  /// Persisted drawing strokes (loaded from server + incremental WS updates).
  final List<CanvasStroke> strokes;

  /// Persisted images (loaded from server + incremental WS updates).
  final List<CanvasImage> images;

  /// Avatar positions for all known participants.
  /// Keyed by userId (string).  Not persisted — reset when user rejoins.
  final Map<String, AvatarPosition> avatarPositions;

  /// Points being accumulated for the currently-in-progress stroke.
  /// Cleared and appended to [strokes] on pointer-up.
  final List<CanvasPoint> activePoints;

  final CanvasTool selectedTool;
  final Color currentColor;
  final double strokeWidth;

  /// True once the initial canvas state has been fetched from the server.
  final bool isLoaded;

  const CanvasState({
    this.strokes = const [],
    this.images = const [],
    this.avatarPositions = const {},
    this.activePoints = const [],
    this.selectedTool = CanvasTool.none,
    this.currentColor = const Color(0xFFFFFFFF),
    this.strokeWidth = 3.0,
    this.isLoaded = false,
  });

  // @S107: API-stable, params are externally fixed by serialization format.
  // The constructor params match the wire format for canvas state; copyWith
  // signature mirrors the constructor. Refactoring would require protocol changes.
  CanvasState copyWith({
    List<CanvasStroke>? strokes,
    List<CanvasImage>? images,
    Map<String, AvatarPosition>? avatarPositions,
    List<CanvasPoint>? activePoints,
    CanvasTool? selectedTool,
    Color? currentColor,
    double? strokeWidth,
    bool? isLoaded,
  }) => CanvasState(
    strokes: strokes ?? this.strokes,
    images: images ?? this.images,
    avatarPositions: avatarPositions ?? this.avatarPositions,
    activePoints: activePoints ?? this.activePoints,
    selectedTool: selectedTool ?? this.selectedTool,
    currentColor: currentColor ?? this.currentColor,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    isLoaded: isLoaded ?? this.isLoaded,
  );
}
