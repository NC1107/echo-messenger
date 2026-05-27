import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' show Color;
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/canvas_models.dart';
import '../services/debug_log_service.dart';
import '../utils/canvas_utils.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';
import 'websocket_provider.dart';

part 'canvas_provider.g.dart';

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

@Riverpod(keepAlive: true)
class CanvasController extends _$CanvasController {
  /// The channel this canvas is attached to.
  String? _channelId;

  /// The channel currently being attached (set BEFORE the REST fetch
  /// completes). Used by [handleCanvasEvent] to recognise inbound events
  /// for the right channel and buffer them while the snapshot is loading
  /// so they aren't wiped when the fetch result overwrites state.
  String? _attachingChannelId;

  /// Throttle timer for avatar position broadcasts (~20 fps).
  Timer? _avatarThrottle;
  ({String userId, CanvasPoint pos})? _pendingAvatar;

  /// Throttle timer for image move broadcasts (~10 fps).
  Timer? _imageThrottle;
  Map<String, dynamic>? _pendingImageMove;

  /// Throttle timer for partial stroke broadcasts (~30 fps max).
  Timer? _strokeThrottle;
  List<CanvasPoint>? _pendingStrokePoints;

  /// Events buffered while [_channelId] is not yet set (attach race window).
  final List<Map<String, dynamic>> _pendingEvents = [];

  @override
  CanvasState build() {
    ref.onDispose(() {
      _avatarThrottle?.cancel();
      _imageThrottle?.cancel();
      _strokeThrottle?.cancel();
    });
    return const CanvasState();
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Load the persisted canvas state from the server and set up WS listener.
  ///
  /// Race-safe load order:
  ///  1. Mark the channel as "attaching" so [handleCanvasEvent] buffers any
  ///     inbound canvas events for it instead of mutating state directly.
  ///  2. Reset state.
  ///  3. Await the REST snapshot fetch — this populates strokes/images from
  ///     the server's persisted truth.
  ///  4. Promote `_attachingChannelId` to `_channelId` AFTER the fetch result
  ///     has been written to state, so the fetched snapshot can't be
  ///     overwritten by WS events that landed mid-fetch.
  ///  5. Replay buffered events (typically a no-op, but covers the case where
  ///     a peer drew while we were fetching).
  Future<void> attach(String conversationId, String channelId) async {
    if (_channelId == channelId) return; // already attached
    _attachingChannelId = channelId;
    _channelId = null;
    _pendingEvents.clear();
    state = const CanvasState(); // reset while loading

    await _fetchCanvas(conversationId, channelId);

    // Only promote to "attached" if we're still attaching to this channel —
    // a second attach() to a different channel may have superseded us.
    if (_attachingChannelId != channelId) return;
    _channelId = channelId;
    _attachingChannelId = null;

    // Flush any canvas events that landed during the fetch.
    final buffered = List<Map<String, dynamic>>.from(_pendingEvents);
    _pendingEvents.clear();
    for (final event in buffered) {
      handleCanvasEvent(event);
    }
  }

  /// Detach from the current channel (called when the voice session ends).
  void detach() {
    _avatarThrottle?.cancel();
    _avatarThrottle = null;
    _pendingAvatar = null;
    _imageThrottle?.cancel();
    _imageThrottle = null;
    _pendingImageMove = null;
    _strokeThrottle?.cancel();
    _strokeThrottle = null;
    _pendingStrokePoints = null;
    _pendingEvents.clear();
    _channelId = null;
    _attachingChannelId = null;
    state = const CanvasState();
  }

  // -------------------------------------------------------------------------
  // REST: load initial canvas state
  // -------------------------------------------------------------------------

  Future<void> _fetchCanvas(String conversationId, String channelId) async {
    final auth = ref.read(authProvider);
    final token = auth.token;
    if (token == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    final url = Uri.parse(
      '$serverUrl/api/groups/$conversationId/channels/$channelId/canvas',
    );

    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final strokes = (json['drawing_data'] as List? ?? [])
            .map((s) => CanvasStroke.fromJson(s as Map<String, dynamic>))
            .toList();
        final images = (json['images_data'] as List? ?? [])
            .map((img) => CanvasImage.fromJson(img as Map<String, dynamic>))
            .toList();
        state = state.copyWith(
          strokes: strokes,
          images: images,
          isLoaded: true,
        );
      } else {
        // Canvas may not exist yet — treat as empty board.
        state = state.copyWith(isLoaded: true);
      }
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        'Canvas',
        'Failed to load canvas for channel $channelId: $e',
      );
      state = state.copyWith(isLoaded: true);
    }
  }

  // -------------------------------------------------------------------------
  // Drawing
  // -------------------------------------------------------------------------

  void startStroke(CanvasPoint point) {
    state = state.copyWith(activePoints: [point]);
    _pendingStrokePoints = [point];
  }

  void continueStroke(CanvasPoint point) {
    final tool = state.selectedTool;
    List<CanvasPoint> pts;
    if (isShapeKind(strokeKindForTool(tool))) {
      // Shape tools (line/rect/ellipse) only need first + last point.
      // Replace the trailing point on every move so the preview rubberbands
      // without bloating the points list.
      pts = state.activePoints.isEmpty
          ? [point]
          : [state.activePoints.first, point];
    } else {
      pts = List<CanvasPoint>.from(state.activePoints)..add(point);
    }
    state = state.copyWith(activePoints: pts);

    // Shapes don't need streaming WS partials — the final stroke at endStroke
    // is enough. Freehand keeps the 30 Hz partial broadcast.
    if (!isShapeKind(strokeKindForTool(tool))) {
      _pendingStrokePoints ??= [];
      _pendingStrokePoints!.add(point);
      _strokeThrottle ??= Timer.periodic(
        const Duration(milliseconds: 33), // ~30 fps
        (_) => _flushStrokePoints(),
      );
    }
  }

  void _flushStrokePoints() {
    final pending = _pendingStrokePoints;
    if (pending == null || pending.isEmpty) {
      _strokeThrottle?.cancel();
      _strokeThrottle = null;
      return;
    }
    _pendingStrokePoints = null;
    final tool = state.selectedTool;
    final kind = strokeKindForTool(tool);
    final isEraser = kind == StrokeKind.eraser;
    _sendCanvasEvent('stroke_partial', {
      'points': pending.map((p) => {'x': p.x, 'y': p.y}).toList(),
      'color': isEraser ? '#00000000' : colorToHex(state.currentColor),
      'width': _effectiveStrokeWidth(kind),
      'kind': _strokeKindWire(kind),
    });
  }

  /// Reverse of [_strokeKindWire] — used when reconstructing strokes from
  /// inbound `stroke_partial` events so all stroke kinds (highlighter,
  /// shapes, text) render correctly mid-drag instead of being coerced to
  /// plain pen.
  StrokeKind _wireKindToStrokeKind(String kind) {
    switch (kind) {
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

  /// Wire `kind` string per protocol — falls back to "pen" for unknown.
  /// Mirrors the mapping in [CanvasStroke.toJson] but kept independent so
  /// stroke_partial events don't need to construct a full stroke.
  String _strokeKindWire(StrokeKind kind) {
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

  /// Commit a text label at [anchor]. Persisted as a stroke (kind=text) so
  /// it round-trips through the existing canvas tables — no schema change.
  void addTextLabel({
    required CanvasPoint anchor,
    required String text,
    required double fontSize,
    required Color color,
  }) {
    if (_channelId == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final stroke = CanvasStroke(
      id: newCanvasId(),
      color: colorToHex(color),
      width: fontSize,
      points: [anchor],
      kind: StrokeKind.text,
      text: trimmed,
    );
    final newStrokes = List<CanvasStroke>.from(state.strokes)..add(stroke);
    state = state.copyWith(strokes: newStrokes);
    _myStrokeIds.add(stroke.id);
    _sendCanvasEvent('stroke', stroke.toJson());
  }

  /// Eraser is rendered 3× the selected width so the user can wipe a
  /// reasonable area without dialing the size slider up.
  double _effectiveStrokeWidth(StrokeKind kind) {
    if (kind == StrokeKind.eraser) return state.strokeWidth * 3;
    return state.strokeWidth;
  }

  void endStroke() {
    if (state.activePoints.isEmpty) return;
    if (_channelId == null) return;

    // Flush any remaining pending points immediately.
    _strokeThrottle?.cancel();
    _strokeThrottle = null;
    _pendingStrokePoints = null;

    final tool = state.selectedTool;
    final kind = strokeKindForTool(tool);
    final isEraser = kind == StrokeKind.eraser;
    final stroke = CanvasStroke(
      id: newCanvasId(),
      color: isEraser ? '#00000000' : colorToHex(state.currentColor),
      width: _effectiveStrokeWidth(kind),
      points: List.from(state.activePoints),
      kind: kind,
    );

    // Append locally.
    final newStrokes = List<CanvasStroke>.from(state.strokes)..add(stroke);
    state = state.copyWith(strokes: newStrokes, activePoints: []);
    _myStrokeIds.add(stroke.id);

    // Broadcast complete stroke and persist via WebSocket.
    _sendCanvasEvent('stroke', stroke.toJson());
  }

  void clearDrawing() {
    if (_channelId == null) return;
    state = state.copyWith(strokes: [], images: []);
    _myStrokeIds.clear();
    _sendCanvasEvent('clear', {});
  }

  /// Clear only the strokes / images that THIS client created in the current
  /// session. Other participants' content is preserved. Tracked via
  /// [_myStrokeIds] which is appended to whenever this client commits a
  /// stroke or text label. The set is session-local so a rejoined client
  /// can't reach back and delete strokes from a prior session — that's a
  /// feature, not a bug; reattribution would need server-side sender IDs.
  void clearMyDrawings() {
    if (_channelId == null) return;
    if (_myStrokeIds.isEmpty) return;
    final remainingStrokes = state.strokes
        .where((s) => !_myStrokeIds.contains(s.id))
        .toList();
    final remainingImages = state.images
        .where((img) => !_myImageIds.contains(img.id))
        .toList();
    _myStrokeIds.clear();
    _myImageIds.clear();
    // importSnapshot broadcasts the new state (clear + re-add) so remote
    // peers converge on the same set of strokes + images.
    importSnapshot(strokes: remainingStrokes, images: remainingImages);
  }

  /// IDs of strokes this client originated in the current session. Used by
  /// [clearMyDrawings] to scope the clear to "mine" rather than wiping the
  /// whole canvas.
  final Set<String> _myStrokeIds = {};
  final Set<String> _myImageIds = {};

  /// Replace the local canvas state with a previously-exported snapshot and
  /// broadcast it to the rest of the participants. Used by the JSON import
  /// affordance — sends a `clear`, then `image_add` for every image, then
  /// `stroke` for every stroke, so remote clients converge.
  void importSnapshot({
    required List<CanvasStroke> strokes,
    required List<CanvasImage> images,
  }) {
    state = state.copyWith(strokes: strokes, images: images);
    if (_channelId == null) return;
    _sendCanvasEvent('clear', {});
    for (final img in images) {
      _sendCanvasEvent('image_add', img.toJson());
    }
    for (final stroke in strokes) {
      _sendCanvasEvent('stroke', stroke.toJson());
    }
  }

  // -------------------------------------------------------------------------
  // Images
  // -------------------------------------------------------------------------

  void addImage(CanvasImage image) {
    if (_channelId == null) return;
    final newImages = List<CanvasImage>.from(state.images)..add(image);
    state = state.copyWith(images: newImages);
    _myImageIds.add(image.id);
    _sendCanvasEvent('image_add', image.toJson());
  }

  void moveImage(String imageId, double x, double y) {
    if (_channelId == null) return;
    final idx = state.images.indexWhere((img) => img.id == imageId);
    if (idx == -1) return;
    final updated = state.images[idx].copyWith(x: x, y: y);
    final newImages = List<CanvasImage>.from(state.images)..[idx] = updated;
    state = state.copyWith(images: newImages);

    _pendingImageMove = updated.toJson();
    _imageThrottle ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _flushImageMove(),
    );
  }

  void _flushImageMove() {
    final pending = _pendingImageMove;
    if (pending == null) {
      _imageThrottle?.cancel();
      _imageThrottle = null;
      return;
    }
    _pendingImageMove = null;
    _sendCanvasEvent('image_move', pending);
  }

  /// Called when image drag ends -- flush immediately.
  void commitImageMove(String imageId, double x, double y) {
    _imageThrottle?.cancel();
    _imageThrottle = null;
    _pendingImageMove = null;

    if (_channelId == null) return;
    final idx = state.images.indexWhere((img) => img.id == imageId);
    if (idx == -1) return;
    final updated = state.images[idx].copyWith(x: x, y: y);
    final newImages = List<CanvasImage>.from(state.images)..[idx] = updated;
    state = state.copyWith(images: newImages);
    _sendCanvasEvent('image_move', updated.toJson());
  }

  void removeImage(String imageId) {
    if (_channelId == null) return;
    final newImages = state.images.where((img) => img.id != imageId).toList();
    state = state.copyWith(images: newImages);
    _sendCanvasEvent('image_remove', {'id': imageId});
  }

  /// Live-resize throttle: piggybacks on the existing image_move WS event so
  /// the server's update_image upserts the new size without any server-side
  /// changes (CanvasImage.toJson includes width + height).
  void resizeImage(String imageId, double width, double height) {
    if (_channelId == null) return;
    final idx = state.images.indexWhere((img) => img.id == imageId);
    if (idx == -1) return;
    final clampedW = width.clamp(0.05, 1.0);
    final clampedH = height.clamp(0.05, 1.0);
    final updated = state.images[idx].copyWith(
      width: clampedW,
      height: clampedH,
    );
    final newImages = List<CanvasImage>.from(state.images)..[idx] = updated;
    state = state.copyWith(images: newImages);

    _pendingImageMove = updated.toJson();
    _imageThrottle ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _flushImageMove(),
    );
  }

  /// Flushes the pending resize state immediately on pointer-up.
  void commitImageResize(String imageId) {
    _imageThrottle?.cancel();
    _imageThrottle = null;
    _pendingImageMove = null;

    if (_channelId == null) return;
    final idx = state.images.indexWhere((img) => img.id == imageId);
    if (idx == -1) return;
    _sendCanvasEvent('image_move', state.images[idx].toJson());
  }

  // -------------------------------------------------------------------------
  // Avatars
  // -------------------------------------------------------------------------

  /// Called while the user is dragging their avatar.  Updates local state
  /// immediately and queues a throttled WS broadcast. The current scale is
  /// preserved.
  void moveLocalAvatar(String userId, CanvasPoint pos) {
    final existing = state.avatarPositions[userId];
    final scale = existing?.scale ?? 1.0;
    final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
    updated[userId] = AvatarPosition(
      userId: userId,
      x: pos.x,
      y: pos.y,
      scale: scale,
    );
    state = state.copyWith(avatarPositions: updated);

    _pendingAvatar = (userId: userId, pos: pos);
    _avatarThrottle ??= Timer.periodic(
      const Duration(milliseconds: 50), // ~20 fps for smoother avatar sync
      (_) => _flushAvatarMove(),
    );
  }

  void _flushAvatarMove() {
    final pending = _pendingAvatar;
    if (pending == null) {
      _avatarThrottle?.cancel();
      _avatarThrottle = null;
      return;
    }
    _pendingAvatar = null;
    final existing = state.avatarPositions[pending.userId];
    _sendCanvasEvent('avatar_move', {
      'user_id': pending.userId,
      'x': pending.pos.x,
      'y': pending.pos.y,
      'scale': existing?.scale ?? 1.0,
    });
  }

  /// Called while the user is dragging an avatar's resize handle. Same
  /// throttling as [moveLocalAvatar] — broadcasts ride the existing
  /// `avatar_move` channel, server is passthrough.
  void resizeAvatar(String userId, double scale) {
    final clamped = scale.clamp(
      AvatarPosition.minScale,
      AvatarPosition.maxScale,
    );
    final existing = state.avatarPositions[userId];
    final pos = existing != null
        ? CanvasPoint(x: existing.x, y: existing.y)
        : const CanvasPoint(x: 0.5, y: 0.5);
    final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
    updated[userId] = AvatarPosition(
      userId: userId,
      x: pos.x,
      y: pos.y,
      scale: clamped,
    );
    state = state.copyWith(avatarPositions: updated);

    _pendingAvatar = (userId: userId, pos: pos);
    _avatarThrottle ??= Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _flushAvatarMove(),
    );
  }

  /// Flushes the pending avatar resize immediately on pointer-up.
  void commitAvatarResize(String userId) {
    _avatarThrottle?.cancel();
    _avatarThrottle = null;
    _pendingAvatar = null;

    if (_channelId == null) return;
    final existing = state.avatarPositions[userId];
    if (existing == null) return;
    _sendCanvasEvent('avatar_move', {
      'user_id': userId,
      'x': existing.x,
      'y': existing.y,
      'scale': existing.scale,
    });
  }

  /// Called when the user stops dragging (send final position immediately).
  void commitLocalAvatarMove(String userId, CanvasPoint pos) {
    _avatarThrottle?.cancel();
    _avatarThrottle = null;
    _pendingAvatar = null;

    final existing = state.avatarPositions[userId];
    final scale = existing?.scale ?? 1.0;
    final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
    updated[userId] = AvatarPosition(
      userId: userId,
      x: pos.x,
      y: pos.y,
      scale: scale,
    );
    state = state.copyWith(avatarPositions: updated);
    _sendCanvasEvent('avatar_move', {
      'user_id': userId,
      'x': pos.x,
      'y': pos.y,
      'scale': scale,
    });
  }

  // -------------------------------------------------------------------------
  // Tool / color / width
  // -------------------------------------------------------------------------

  void setTool(CanvasTool tool) => state = state.copyWith(selectedTool: tool);
  void setColor(Color color) => state = state.copyWith(currentColor: color);
  void setStrokeWidth(double w) => state = state.copyWith(strokeWidth: w);

  // -------------------------------------------------------------------------
  // Incoming WebSocket canvas events
  // -------------------------------------------------------------------------

  void handleCanvasEvent(Map<String, dynamic> json) {
    final channelId = json['channel_id'] as String?;
    // Buffer events that arrive before attach() has set _channelId.  They
    // will be replayed once attach() completes and _channelId is known.
    // Also buffer events that arrive WHILE attach()'s REST snapshot is
    // in flight for this channel — applying them mid-fetch is unsafe
    // because the fetch result will overwrite state and discard the
    // WS-derived stroke (regression: late joiners drawing during another
    // peer's fetch would vanish on the late-joiner's side).
    if (_channelId == null) {
      if (_attachingChannelId == null || channelId == _attachingChannelId) {
        _pendingEvents.add(json);
      }
      return;
    }
    if (channelId != _channelId) return; // event for a different channel

    final kind = json['kind'] as String?;
    final payload = json['payload'] as Map<String, dynamic>? ?? {};
    final fromUserId = json['from_user_id'] as String? ?? '';

    switch (kind) {
      case 'stroke_partial':
        // Partial stroke delta: points arriving incrementally.
        // Build a temporary stroke and add it for live display.
        final pointsList = (payload['points'] as List? ?? [])
            .map(
              (p) => CanvasPoint(
                x: (p['x'] as num?)?.toDouble() ?? 0.0,
                y: (p['y'] as num?)?.toDouble() ?? 0.0,
              ),
            )
            .toList();
        final color = payload['color'] as String? ?? '#000000';
        final width = (payload['width'] as num?)?.toDouble() ?? 2.0;
        final kind = payload['kind'] as String? ?? 'pen';

        if (pointsList.isEmpty) return;

        // Look for an existing partial stroke from this user.
        final partialId = 'partial_${fromUserId}_in_progress';
        final existingIdx = state.strokes.indexWhere((s) => s.id == partialId);

        if (existingIdx != -1) {
          // Append points to existing partial stroke.
          final existing = state.strokes[existingIdx];
          final updated = existing.copyWith(
            points: List.from(existing.points)..addAll(pointsList),
          );
          final newStrokes = List<CanvasStroke>.from(state.strokes)
            ..[existingIdx] = updated;
          state = state.copyWith(strokes: newStrokes);
        } else {
          // Honour the wire `kind` so highlighter partials render as a
          // translucent thick pen on remotes instead of being coerced to
          // plain pen. Falls through `_strokeKindFromString` for any
          // value the receiver doesn't recognise.
          final partialStroke = CanvasStroke(
            id: partialId,
            color: color,
            width: width,
            points: pointsList,
            kind: _wireKindToStrokeKind(kind),
          );
          final newStrokes = List<CanvasStroke>.from(state.strokes)
            ..add(partialStroke);
          state = state.copyWith(strokes: newStrokes);
        }
      case 'stroke':
        final stroke = CanvasStroke.fromJson(payload);
        // Remove the partial stroke placeholder if it exists.
        final partialId = 'partial_${fromUserId}_in_progress';
        final strokes = state.strokes.where((s) => s.id != partialId).toList()
          ..add(stroke);
        state = state.copyWith(strokes: strokes);
      case 'clear':
        state = state.copyWith(strokes: [], images: []);
      case 'image_add':
        final image = CanvasImage.fromJson(payload);
        final newImages = List<CanvasImage>.from(state.images)..add(image);
        state = state.copyWith(images: newImages);
      case 'image_move':
        final updatedImage = CanvasImage.fromJson(payload);
        final idx = state.images.indexWhere((img) => img.id == updatedImage.id);
        if (idx != -1) {
          final newImages = List<CanvasImage>.from(state.images)
            ..[idx] = updatedImage;
          state = state.copyWith(images: newImages);
        }
      case 'image_remove':
        final id = payload['id'] as String?;
        if (id != null) {
          final newImages = state.images.where((img) => img.id != id).toList();
          state = state.copyWith(images: newImages);
        }
      case 'avatar_move':
        final x = (payload['x'] as num?)?.toDouble() ?? 0.5;
        final y = (payload['y'] as num?)?.toDouble() ?? 0.5;
        // Older clients won't send `scale`; preserve the prior value (or
        // default to 1.0) so a move from an old build doesn't reset the
        // size that a newer participant just resized.
        final existing = state.avatarPositions[fromUserId];
        final rawScale = (payload['scale'] as num?)?.toDouble();
        final scale = (rawScale ?? existing?.scale ?? 1.0).clamp(
          AvatarPosition.minScale,
          AvatarPosition.maxScale,
        );
        final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
        updated[fromUserId] = AvatarPosition(
          userId: fromUserId,
          x: x.clamp(0.0, 1.0),
          y: y.clamp(0.0, 1.0),
          scale: scale,
        );
        state = state.copyWith(avatarPositions: updated);
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _sendCanvasEvent(String kind, Map<String, dynamic> payload) {
    final cid = _channelId;
    if (cid == null) return;

    ref
        .read(websocketProvider.notifier)
        .sendCanvasEvent(channelId: cid, kind: kind, payload: payload);
  }
}

/// Back-compat alias: existing call sites still refer to `canvasProvider`.
/// The class is named `CanvasController` to avoid shadowing dart:ui.Canvas
/// inside this library.
final canvasProvider = canvasControllerProvider;
