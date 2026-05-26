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
  Future<void> attach(String conversationId, String channelId) async {
    if (_channelId == channelId) return; // already attached
    _channelId = channelId;
    state = const CanvasState(); // reset while loading

    await _fetchCanvas(conversationId, channelId);

    // Flush any canvas events that arrived before _channelId was set.
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
    final pts = List<CanvasPoint>.from(state.activePoints)..add(point);
    state = state.copyWith(activePoints: pts);

    // Buffer the new point for throttled broadcast.
    _pendingStrokePoints ??= [];
    _pendingStrokePoints!.add(point);

    // Start throttle timer if not already running.
    _strokeThrottle ??= Timer.periodic(
      const Duration(milliseconds: 33), // ~30 fps
      (_) => _flushStrokePoints(),
    );
  }

  void _flushStrokePoints() {
    final pending = _pendingStrokePoints;
    if (pending == null || pending.isEmpty) {
      _strokeThrottle?.cancel();
      _strokeThrottle = null;
      return;
    }
    _pendingStrokePoints = null;
    final isEraser = state.selectedTool == CanvasTool.eraser;
    _sendCanvasEvent('stroke_partial', {
      'points': pending.map((p) => {'x': p.x, 'y': p.y}).toList(),
      'color': isEraser ? '#00000000' : colorToHex(state.currentColor),
      'width': isEraser ? state.strokeWidth * 3 : state.strokeWidth,
      'kind': isEraser ? 'eraser' : 'pen',
    });
  }

  void endStroke() {
    if (state.activePoints.isEmpty) return;
    if (_channelId == null) return;

    // Flush any remaining pending points immediately.
    _strokeThrottle?.cancel();
    _strokeThrottle = null;
    _pendingStrokePoints = null;

    final isEraser = state.selectedTool == CanvasTool.eraser;
    final stroke = CanvasStroke(
      id: newCanvasId(),
      color: isEraser ? '#00000000' : colorToHex(state.currentColor),
      width: isEraser ? state.strokeWidth * 3 : state.strokeWidth,
      points: List.from(state.activePoints),
      kind: isEraser ? StrokeKind.eraser : StrokeKind.pen,
    );

    // Append locally.
    final newStrokes = List<CanvasStroke>.from(state.strokes)..add(stroke);
    state = state.copyWith(strokes: newStrokes, activePoints: []);

    // Broadcast complete stroke and persist via WebSocket.
    _sendCanvasEvent('stroke', stroke.toJson());
  }

  void clearDrawing() {
    if (_channelId == null) return;
    state = state.copyWith(strokes: [], images: []);
    _sendCanvasEvent('clear', {});
  }

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
  /// immediately and queues a throttled WS broadcast.
  void moveLocalAvatar(String userId, CanvasPoint pos) {
    final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
    updated[userId] = AvatarPosition(userId: userId, x: pos.x, y: pos.y);
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
    _sendCanvasEvent('avatar_move', {
      'user_id': pending.userId,
      'x': pending.pos.x,
      'y': pending.pos.y,
    });
  }

  /// Called when the user stops dragging (send final position immediately).
  void commitLocalAvatarMove(String userId, CanvasPoint pos) {
    _avatarThrottle?.cancel();
    _avatarThrottle = null;
    _pendingAvatar = null;

    final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
    updated[userId] = AvatarPosition(userId: userId, x: pos.x, y: pos.y);
    state = state.copyWith(avatarPositions: updated);
    _sendCanvasEvent('avatar_move', {
      'user_id': userId,
      'x': pos.x,
      'y': pos.y,
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
    if (_channelId == null) {
      _pendingEvents.add(json);
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
          // Create new partial stroke.
          final partialStroke = CanvasStroke(
            id: partialId,
            color: color,
            width: width,
            points: pointsList,
            kind: kind == 'eraser' ? StrokeKind.eraser : StrokeKind.pen,
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
        final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
        updated[fromUserId] = AvatarPosition(
          userId: fromUserId,
          x: x.clamp(0.0, 1.0),
          y: y.clamp(0.0, 1.0),
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
