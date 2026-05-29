import 'dart:ui' show Color;

// ---------------------------------------------------------------------------
// Canvas geometry helpers
// ---------------------------------------------------------------------------

/// Virtual canvas size. 100k×100k is large enough to feel infinite for any
/// realistic call (at default 1× zoom you'd have to drag your finger across
/// the screen ~250 times to cross it) while staying inside the range where
/// Flutter's transformation math and floating-point precision behave well.
/// Treat the lounge as a Figma-style pannable surface where the user lands
/// in a default region (origin, or the bbox of existing content on
/// rejoin) and can zoom out repeatedly to see more.
///
/// Old call-sites of `kCanvasWidth` from the 4096-era still work as a
/// "clamp coords to the canvas" guard, but the value is now so large the
/// clamp is effectively a no-op for any realistic input.
const double kCanvasWidth = 100000;
const double kCanvasHeight = 100000;

/// Legacy 4096-px canvas size, used by [_migrateLegacyCoord] so old
/// persisted strokes land where they were drawn (in the top-left 4% of
/// the new 100k space) instead of being rescaled to fill the new range.
/// Auto-fit-to-content on join zooms the user to that region naturally,
/// so users never notice the canvas got bigger underneath them.
const double _kLegacyNormalisedScale = 4096;

/// Running count of how many times [_migrateLegacyCoord] has applied the
/// 0..1 → 4096-scale heuristic since app launch. Used to determine when it
/// is safe to delete the helper (see docs/voice-lounge/01-coordinate-policy.md
/// "Legacy-coord migration sunset").
int _legacyMigrationCount = 0;

/// Number of times the legacy-coord migration heuristic has fired in this
/// app session.
int get legacyMigrationCount => _legacyMigrationCount;

/// Resets [legacyMigrationCount] to zero. Call this between tests or at
/// app-start if you want a clean per-session counter.
void resetLegacyMigrationCount() => _legacyMigrationCount = 0;

/// Migrates very old (pre-4096) coordinates persisted as normalized 0..1
/// fractions of the viewport. Returns absolute canvas-space pixels.
///
/// Heuristic: a `value <= 1.0` is interpreted as normalised and multiplied
/// by [_kLegacyNormalisedScale] (NOT by [kCanvasWidth] — multiplying by
/// 100k would scatter old drawings across the entire new space, breaking
/// their relative positions). 4096-era and 100k-era coords (anything > 1)
/// pass through unchanged. The `axisExtent` parameter is now unused but
/// kept for call-site compatibility; remove on the next sweep.
double _migrateLegacyCoord(double value, double axisExtent) {
  if (value <= 1.0) {
    _legacyMigrationCount++;
    return value * _kLegacyNormalisedScale;
  }
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
// Screen-share window positions
// ---------------------------------------------------------------------------

/// Position + size of a draggable screen-share window on the canvas.
///
/// Coordinates and dimensions are in **CSS pixels** relative to the
/// lounge viewport's top-left (NOT normalized [0, 1] like
/// [AvatarPosition]). The window has its own intrinsic aspect ratio so
/// scaling it by canvas size would distort the underlying video; clients
/// agree on raw pixel coordinates instead and rely on the canvas size
/// being roughly consistent across participants.
///
/// [windowId] is a stable per-stream identifier — for remote screen
/// shares it's `screenshare-{participantSid}` and for the host's own
/// preview it's `screenshare-local`. Broadcast over WebSocket as the
/// `screenshare_move` event; ephemeral (never persisted server-side).
class ScreenShareWindow {
  final String windowId;
  final double x;
  final double y;
  final double width;
  final double height;

  const ScreenShareWindow({
    required this.windowId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory ScreenShareWindow.fromJson(Map<String, dynamic> json) =>
      ScreenShareWindow(
        windowId: json['window_id'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
    'window_id': windowId,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  ScreenShareWindow copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
  }) => ScreenShareWindow(
    windowId: windowId,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScreenShareWindow &&
          windowId == other.windowId &&
          x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height);

  @override
  int get hashCode => Object.hash(windowId, x, y, width, height);
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
// Canvas attach state
// ---------------------------------------------------------------------------

/// Lifecycle state for the canvas snapshot fetch.
///
/// - [idle] — no attach in progress (initial or after detach).
/// - [loading] — REST snapshot fetch is in flight.
/// - [loaded] — snapshot fetched and applied; canvas is live.
/// - [failed] — fetch threw or returned a non-2xx response.
enum CanvasAttachState { idle, loading, loaded, failed }

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

  /// Screen-share window positions, keyed by `windowId` (e.g.
  /// `screenshare-{participantSid}` for remote shares, `screenshare-local`
  /// for the host's own preview). Like [avatarPositions], these are
  /// ephemeral — broadcast over the `screenshare_move` WS event and
  /// never persisted server-side.
  final Map<String, ScreenShareWindow> screenSharePositions;

  /// Points being accumulated for the currently-in-progress stroke.
  /// Cleared and appended to [strokes] on pointer-up.
  final List<CanvasPoint> activePoints;

  final CanvasTool selectedTool;
  final Color currentColor;
  final double strokeWidth;

  /// True once the initial canvas state has been fetched from the server.
  final bool isLoaded;

  /// Lifecycle state of the snapshot fetch. Drives [CanvasLoadingBanner].
  final CanvasAttachState attachState;

  /// When the most recent [attach] call started. Used by [CanvasLoadingBanner]
  /// to detect slow connections (> 8 s without transitioning away from
  /// [CanvasAttachState.loading]).
  final DateTime? attachStartedAt;

  const CanvasState({
    this.strokes = const [],
    this.images = const [],
    this.avatarPositions = const {},
    this.screenSharePositions = const {},
    this.activePoints = const [],
    this.selectedTool = CanvasTool.none,
    this.currentColor = const Color(0xFFFFFFFF),
    this.strokeWidth = 3.0,
    this.isLoaded = false,
    this.attachState = CanvasAttachState.idle,
    this.attachStartedAt,
  });

  // @S107: API-stable, params are externally fixed by serialization format.
  // The constructor params match the wire format for canvas state; copyWith
  // signature mirrors the constructor. Refactoring would require protocol changes.
  CanvasState copyWith({
    List<CanvasStroke>? strokes,
    List<CanvasImage>? images,
    Map<String, AvatarPosition>? avatarPositions,
    Map<String, ScreenShareWindow>? screenSharePositions,
    List<CanvasPoint>? activePoints,
    CanvasTool? selectedTool,
    Color? currentColor,
    double? strokeWidth,
    bool? isLoaded,
    CanvasAttachState? attachState,
    DateTime? attachStartedAt,
  }) => CanvasState(
    strokes: strokes ?? this.strokes,
    images: images ?? this.images,
    avatarPositions: avatarPositions ?? this.avatarPositions,
    screenSharePositions: screenSharePositions ?? this.screenSharePositions,
    activePoints: activePoints ?? this.activePoints,
    selectedTool: selectedTool ?? this.selectedTool,
    currentColor: currentColor ?? this.currentColor,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    isLoaded: isLoaded ?? this.isLoaded,
    attachState: attachState ?? this.attachState,
    attachStartedAt: attachStartedAt ?? this.attachStartedAt,
  );
}
