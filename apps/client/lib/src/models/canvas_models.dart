import 'dart:ui' show Color;

// ---------------------------------------------------------------------------
// Canvas geometry helpers
// ---------------------------------------------------------------------------

/// A 2-D point with coordinates normalized to the range [0, 1] relative to
/// the canvas size.  Normalization ensures the layout transfers correctly
/// between participants using different screen sizes.
class CanvasPoint {
  final double x;
  final double y;

  const CanvasPoint({required this.x, required this.y});

  factory CanvasPoint.fromJson(Map<String, dynamic> json) => CanvasPoint(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
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

enum StrokeKind { pen, eraser }

/// A single freehand stroke drawn on the canvas.
class CanvasStroke {
  final String id;
  final String color; // CSS hex color, e.g. "#FF5500" or "#00000000" for eraser
  final double width; // brush width in logical pixels (before normalization)
  final List<CanvasPoint> points;
  final StrokeKind kind;

  const CanvasStroke({
    required this.id,
    required this.color,
    required this.width,
    required this.points,
    this.kind = StrokeKind.pen,
  });

  factory CanvasStroke.fromJson(Map<String, dynamic> json) => CanvasStroke(
    id: json['id'] as String,
    color: json['color'] as String,
    width: (json['width'] as num).toDouble(),
    points: (json['points'] as List)
        .map((p) => CanvasPoint.fromJson(p as Map<String, dynamic>))
        .toList(),
    kind: (json['kind'] as String?) == 'eraser'
        ? StrokeKind.eraser
        : StrokeKind.pen,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'color': color,
    'width': width,
    'points': points.map((p) => p.toJson()).toList(),
    'kind': kind == StrokeKind.eraser ? 'eraser' : 'pen',
  };

  CanvasStroke copyWith({
    String? id,
    String? color,
    double? width,
    List<CanvasPoint>? points,
    StrokeKind? kind,
  }) => CanvasStroke(
    id: id ?? this.id,
    color: color ?? this.color,
    width: width ?? this.width,
    points: points ?? this.points,
    kind: kind ?? this.kind,
  );
}

// ---------------------------------------------------------------------------
// Canvas images
// ---------------------------------------------------------------------------

/// An image pinned to the canvas (pasted from clipboard or drag-dropped).
///
/// All coordinates and dimensions are normalized [0, 1] relative to the
/// canvas size so they display correctly on every screen resolution.
class CanvasImage {
  final String id;
  final String url; // absolute URL served via /api/media/{id}
  final double x; // normalized left edge
  final double y; // normalized top edge
  final double width; // normalized width (fraction of canvas width)
  final double height; // normalized height (fraction of canvas height)

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
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
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
/// Coordinates are normalized [0, 1].  The local user's own position is
/// tracked separately and broadcast via WebSocket on drag-end.
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

enum CanvasTool { none, pen, eraser }

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
