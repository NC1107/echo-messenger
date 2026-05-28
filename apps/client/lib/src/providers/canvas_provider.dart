import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// Per-drag identifier bumped by [startStroke]. A late `stroke_partial`
  /// scheduled mid-drag could otherwise fire AFTER [endStroke] cleared the
  /// throttle, re-attaching a stale partial placeholder on remotes that
  /// overlays the now-final stroke. Tracking this id and checking it inside
  /// [_flushStrokePoints] makes the late timer a no-op once endStroke has
  /// closed the drag (bug report 2026-05-27 "hold finger at the end of a
  /// line — local sees it, remotes don't").
  int _dragId = 0;
  bool _strokeActive = false;

  /// Guards the once-per-session legacy-coord telemetry log so it only
  /// fires on the first [attach] call (i.e. when the user first joins a
  /// lounge this session, not on every channel switch).
  bool _legacyCoordLogged = false;

  /// Events buffered while [_channelId] is not yet set (attach race window).
  final List<Map<String, dynamic>> _pendingEvents = [];

  @override
  CanvasState build() {
    ref.onDispose(() {
      _avatarThrottle?.cancel();
      _imageThrottle?.cancel();
      _strokeThrottle?.cancel();
      _screenShareThrottle?.cancel();
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

    // Once per session: log the legacy-coord migration counter so we can
    // track when it is safe to delete _migrateLegacyCoord (see
    // docs/voice-lounge/01-coordinate-policy.md "Legacy-coord migration sunset").
    if (!_legacyCoordLogged) {
      _legacyCoordLogged = true;
      DebugLogService.instance.log(
        LogLevel.info,
        'Canvas',
        '[legacy-coord] migrations this session = $legacyMigrationCount',
      );
    }

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
    _strokeActive = false;
    _screenShareThrottle?.cancel();
    _screenShareThrottle = null;
    _pendingScreenShare = null;
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
    // Bump the drag id BEFORE any timer state mutates so a tick scheduled
    // by the previous drag (still queued after endStroke cancelled it)
    // can't attach to this new stroke. Also cancel any lingering throttle
    // defensively — endStroke should have done this already, but the
    // gesture-arena steal path documented in voice_canvas.dart can skip
    // endStroke entirely.
    _strokeThrottle?.cancel();
    _strokeThrottle = null;
    _pendingStrokePoints = null;
    _dragId++;
    _strokeActive = true;
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
    // If endStroke (or a tool change) has closed the drag, drop any tick
    // that fires after the close — the final `stroke` event is the source
    // of truth.
    if (!_strokeActive) {
      _strokeThrottle?.cancel();
      _strokeThrottle = null;
      _pendingStrokePoints = null;
      return;
    }
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
    // Always close the drag, even if we have nothing to commit — a gesture
    // cancel from InteractiveViewer reclaiming the pointer mid-stroke
    // (Listener.onPointerCancel) still needs to flip `_strokeActive` so a
    // queued partial-flush tick doesn't fire afterwards.
    final wasActive = _strokeActive;
    _strokeActive = false;
    // Atomic cancel+null — done BEFORE building the final stroke so a
    // partial timer that races us can't slip a stroke_partial event after
    // the final stroke is sent.
    _strokeThrottle?.cancel();
    _strokeThrottle = null;
    _pendingStrokePoints = null;

    if (!wasActive) return;
    if (state.activePoints.isEmpty) return;
    if (_channelId == null) return;

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
    // Reset BOTH mine-sets — the previous code only cleared strokes, so
    // a subsequent "Clear my drawings" would believe the user still had
    // images to scope-clear and replay an empty snapshot (audit Finding
    // 5, 2026-05-28).
    _myStrokeIds.clear();
    _myImageIds.clear();
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
    // Min 32 px so images never shrink below a usable thumbnail; max is the
    // full canvas extent so callers don't need to clamp upstream.
    final clampedW = width.clamp(32.0, kCanvasWidth);
    final clampedH = height.clamp(32.0, kCanvasHeight);
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

  /// Called while a user is dragging an avatar — either their own or
  /// somebody else's. Updates local state immediately and queues a
  /// throttled WS broadcast. The current scale is preserved.
  ///
  /// The voice-lounge canvas is a shared whiteboard: any participant
  /// can move any avatar, and the broadcast carries the *target*
  /// `userId` in the payload so receivers update the right entry.
  void moveAvatar(String userId, CanvasPoint pos) {
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
        : const CanvasPoint(x: kCanvasWidth / 2, y: kCanvasHeight / 2);
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

  /// Called when the user stops dragging an avatar (any avatar, theirs
  /// or someone else's). Sends the final position immediately.
  void commitAvatarMove(String userId, CanvasPoint pos) {
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
  // Screen-share window positions
  //
  // Like avatar moves these are ephemeral — the server relays but does not
  // persist them. The `screenshare_move` event mirrors `avatar_move` in
  // shape (window_id, x, y, width, height) so the same throttle/commit
  // pattern applies, and clients agree on raw CSS pixels (NOT normalized)
  // since the window has its own intrinsic aspect ratio.
  // -------------------------------------------------------------------------

  /// Throttle timer for screen-share window broadcasts (~20 fps).
  Timer? _screenShareThrottle;
  ScreenShareWindow? _pendingScreenShare;

  /// Called while the user drags a screen-share window. Updates local
  /// state immediately and queues a throttled WS broadcast.
  void moveScreenShare({
    required String windowId,
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    final updated = Map<String, ScreenShareWindow>.from(
      state.screenSharePositions,
    );
    final window = ScreenShareWindow(
      windowId: windowId,
      x: x,
      y: y,
      width: width,
      height: height,
    );
    updated[windowId] = window;
    state = state.copyWith(screenSharePositions: updated);

    _pendingScreenShare = window;
    _screenShareThrottle ??= Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _flushScreenShareMove(),
    );
  }

  void _flushScreenShareMove() {
    final pending = _pendingScreenShare;
    if (pending == null) {
      _screenShareThrottle?.cancel();
      _screenShareThrottle = null;
      return;
    }
    _pendingScreenShare = null;
    _sendCanvasEvent('screenshare_move', pending.toJson());
  }

  /// Called when the user releases a screen-share window drag/resize —
  /// flushes the pending broadcast immediately.
  void commitScreenShareMove({
    required String windowId,
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    _screenShareThrottle?.cancel();
    _screenShareThrottle = null;
    _pendingScreenShare = null;

    final window = ScreenShareWindow(
      windowId: windowId,
      x: x,
      y: y,
      width: width,
      height: height,
    );
    final updated = Map<String, ScreenShareWindow>.from(
      state.screenSharePositions,
    );
    updated[windowId] = window;
    state = state.copyWith(screenSharePositions: updated);
    _sendCanvasEvent('screenshare_move', window.toJson());
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
        // Build a temporary stroke and add it for live display. Apply the
        // legacy 0..1 → pixel migration heuristic inline — without this,
        // a pre-4096 client's partial strokes paint into the top-left
        // 1×1 pixel and only "jump" to the right place when the final
        // stroke arrives (audit Finding 6, 2026-05-28).
        final pointsList = (payload['points'] as List? ?? []).map((p) {
          final rawX = (p['x'] as num?)?.toDouble() ?? 0.0;
          final rawY = (p['y'] as num?)?.toDouble() ?? 0.0;
          return CanvasPoint(
            x: rawX <= 1.0 ? rawX * kCanvasWidth : rawX,
            y: rawY <= 1.0 ? rawY * kCanvasHeight : rawY,
          );
        }).toList();
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
        // Remote clear wipes the board for us too — drop the mine-sets so
        // "Clear my drawings" reflects the now-empty canvas.
        _myStrokeIds.clear();
        _myImageIds.clear();
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
        // Shared-whiteboard semantics: the *target* user id is carried in
        // the payload, not derived from the sender. Older clients only
        // ever moved their own avatar and sent `user_id == from_user_id`,
        // so falling back to `fromUserId` keeps them compatible.
        final targetUserId = (payload['user_id'] as String?) ?? fromUserId;
        if (targetUserId.isEmpty) return;
        // Coords arrive in canvas-space pixels on the new wire format.
        // Legacy clients (pre-4096) sent 0..1 normalized — rescale inline
        // using the same heuristic the model layer applies in fromJson.
        final rawX = (payload['x'] as num?)?.toDouble() ?? kCanvasWidth / 2;
        final rawY = (payload['y'] as num?)?.toDouble() ?? kCanvasHeight / 2;
        final x = rawX <= 1.0 ? rawX * kCanvasWidth : rawX;
        final y = rawY <= 1.0 ? rawY * kCanvasHeight : rawY;
        // Older clients won't send `scale`; preserve the prior value (or
        // default to 1.0) so a move from an old build doesn't reset the
        // size that a newer participant just resized.
        final existing = state.avatarPositions[targetUserId];
        final rawScale = (payload['scale'] as num?)?.toDouble();
        final scale = (rawScale ?? existing?.scale ?? 1.0).clamp(
          AvatarPosition.minScale,
          AvatarPosition.maxScale,
        );
        final updated = Map<String, AvatarPosition>.from(state.avatarPositions);
        updated[targetUserId] = AvatarPosition(
          userId: targetUserId,
          x: x.clamp(0.0, kCanvasWidth),
          y: y.clamp(0.0, kCanvasHeight),
          scale: scale,
        );
        state = state.copyWith(avatarPositions: updated);
      case 'screenshare_move':
        final windowId = payload['window_id'] as String?;
        if (windowId == null || windowId.isEmpty) return;
        final x = (payload['x'] as num?)?.toDouble();
        final y = (payload['y'] as num?)?.toDouble();
        if (x == null || y == null) return;
        final existing = state.screenSharePositions[windowId];
        final w =
            (payload['width'] as num?)?.toDouble() ?? existing?.width ?? 320.0;
        final h =
            (payload['height'] as num?)?.toDouble() ??
            existing?.height ??
            180.0;
        final updated = Map<String, ScreenShareWindow>.from(
          state.screenSharePositions,
        );
        updated[windowId] = ScreenShareWindow(
          windowId: windowId,
          x: x,
          y: y,
          width: w,
          height: h,
        );
        state = state.copyWith(screenSharePositions: updated);
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Test-only hooks
  //
  // The partial-stroke flush is driven by an internal Timer that we cannot
  // tick deterministically from a unit test. Exposing a manual flush + the
  // active-drag flag lets the late-partial regression tests assert that a
  // tick scheduled mid-drag is dropped after endStroke / on a fresh drag.
  // ---------------------------------------------------------------------------
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  void debugFlushStrokePoints() => _flushStrokePoints();

  @visibleForTesting
  bool get debugIsStrokeActive => _strokeActive;

  @visibleForTesting
  int get debugDragId => _dragId;

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
