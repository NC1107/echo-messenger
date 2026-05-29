import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart' show Color, Size;
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/canvas_models.dart';
import '../services/canvas_perf.dart';
import '../services/debug_log_service.dart';
import '../utils/canvas_utils.dart';
import 'auth_provider.dart';
import 'canvas_authority_provider.dart';
import 'crypto_provider.dart';
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

  /// Full point list for the currently-in-progress local stroke. Built up
  /// by [startStroke] / [continueStroke] and consumed by [endStroke] to
  /// commit the final stroke and broadcast the `stroke` event.
  ///
  /// Held here -- not in [CanvasState] -- so per-pointer-move ticks bypass
  /// Riverpod's `state = state.copyWith(...)` rebuild path. The local
  /// render reads in-flight points from `ActiveStrokeNotifier` (a
  /// `ChangeNotifier` mounted by `LoungeCanvasStrokes`); the WS partial
  /// broadcast continues to read from [_pendingStrokePoints] below. The
  /// two paths are independent. See
  /// docs/voice-lounge/05-canvas-rewrite-spec.md §B.2.
  List<CanvasPoint>? _strokePoints;

  /// Periodic breadcrumb timer — logs a [CanvasPerf.snapshot] to the debug
  /// log every 30 s while a lounge is active.  Mirrors the PR E pattern.
  Timer? _perfLogTimer;

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

  /// Last (conversationId, channelId) pair passed to [attach]. Stored so
  /// [retryAttach] can re-issue the same request without threading the ids
  /// back through the call-site.
  String? _lastConversationId;
  String? _lastChannelId;

  /// Events buffered while [_channelId] is not yet set (attach race window).
  final List<Map<String, dynamic>> _pendingEvents = [];

  @override
  CanvasState build() {
    ref.onDispose(() {
      _avatarThrottle?.cancel();
      _imageThrottle?.cancel();
      _strokeThrottle?.cancel();
      _screenShareThrottle?.cancel();
      _perfLogTimer?.cancel();
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
    _lastConversationId = conversationId;
    _lastChannelId = channelId;
    // Reset to loading state; record when the fetch started for slow-connection
    // detection in CanvasLoadingBanner.
    state = CanvasState(
      attachState: CanvasAttachState.loading,
      attachStartedAt: DateTime.now(),
    );

    await _fetchCanvas(conversationId, channelId);

    // Only promote to "attached" if we're still attaching to this channel —
    // a second attach() to a different channel may have superseded us.
    if (_attachingChannelId != channelId) return;
    _channelId = channelId;
    _attachingChannelId = null;
    // Promote to loaded only after the stale-channel guard passes.
    state = state.copyWith(attachState: CanvasAttachState.loaded);

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

    // Start the periodic perf breadcrumb (30 s interval, matches PR E pattern).
    _perfLogTimer?.cancel();
    _perfLogTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _logPerfSnapshot(),
    );
  }

  void _logPerfSnapshot() {
    final snap = CanvasPerf.snapshot();
    DebugLogService.instance.log(
      LogLevel.fine,
      'CanvasPerf',
      '[canvas-perf] ${snap.toString()}',
    );
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
    _perfLogTimer?.cancel();
    _perfLogTimer = null;
    _pendingEvents.clear();
    _channelId = null;
    _attachingChannelId = null;
    state = const CanvasState(); // attachState defaults back to idle
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

    // Guards every state write below: if `detach()` cleared
    // `_attachingChannelId` while the HTTP fetch was in flight (user
    // left the lounge mid-load), or a fresh `attach()` superseded us
    // for a different channel, we must NOT write the stale snapshot
    // back into state — doing so re-pollutes the cleared canvas and
    // leaves the lounge in a half-attached state (audit 2026-05-28).
    bool stillAttaching() => _attachingChannelId == channelId;

    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!stillAttaching()) return;
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
        // Canvas may not exist yet — treat as empty board (still valid).
        state = state.copyWith(isLoaded: true);
      }
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        'Canvas',
        'Failed to load canvas for channel $channelId: $e',
      );
      if (!stillAttaching()) return;
      // Network error: mark as failed so the UI can offer a retry.
      state = state.copyWith(
        isLoaded: false,
        attachState: CanvasAttachState.failed,
      );
    }
  }

  /// Re-attempt [attach] with the last channel IDs. No-op when no prior attach
  /// has been recorded (e.g. the notifier was just built).
  Future<void> retryAttach() async {
    final convId = _lastConversationId;
    final chanId = _lastChannelId;
    if (convId == null || chanId == null) return;
    // Force-reset _channelId so the guard in attach() doesn't bail early.
    _channelId = null;
    await attach(convId, chanId);
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
    // The local in-flight preview is driven by ActiveStrokeNotifier (see
    // `LoungeCanvasStrokes`) — we do NOT write activePoints into the
    // provider state on the hot path. Keep two off-state accumulators
    // instead: one for the WS partial broadcast window, and one for the
    // full commit payload.
    _pendingStrokePoints = <CanvasPoint>[point];
    _strokePoints = <CanvasPoint>[point];
  }

  void continueStroke(CanvasPoint point) {
    final sw = Stopwatch()..start();
    final tool = state.selectedTool;
    final isShape = isShapeKind(strokeKindForTool(tool));
    final pts = _strokePoints ??= <CanvasPoint>[];
    if (isShape) {
      // Shape tools (line/rect/ellipse) only need first + last point.
      // Replace the trailing point on every move so the preview
      // rubberbands without bloating the points list.
      if (pts.isEmpty) {
        pts.add(point);
      } else if (pts.length == 1) {
        pts.add(point);
      } else {
        pts[pts.length - 1] = point;
      }
    } else {
      pts.add(point);
    }

    // Shapes don't need streaming WS partials — the final stroke at endStroke
    // is enough. Freehand keeps the 30 Hz partial broadcast.
    if (!isShape) {
      _pendingStrokePoints ??= [];
      _pendingStrokePoints!.add(point);
      _strokeThrottle ??= Timer.periodic(
        const Duration(milliseconds: 33), // ~30 fps
        (_) => _flushStrokePoints(),
      );
    }
    sw.stop();
    CanvasPerf.recordPaintMs(sw.elapsedMicroseconds / 1000.0);
    _warnIfPerfDegraded();
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
    CanvasPerf.recordSendEvent();
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

  /// Cancel the in-flight stroke without committing it. Used by the new
  /// gesture state machine when a second pointer arrives mid-draw
  /// (cancel-then-yield-to-pinch per
  /// docs/voice-lounge/05-canvas-rewrite-spec.md §B.1) and when the user
  /// taps Esc / right-clicks / switches tools mid-stroke. The local
  /// in-flight preview is cleared by [ActiveStrokeNotifier.cancel] on the
  /// gesture-widget side; this method just closes the WS partial broadcast
  /// window and drops the accumulated points so they aren't committed.
  void cancelStroke() {
    _strokeActive = false;
    _strokeThrottle?.cancel();
    _strokeThrottle = null;
    _pendingStrokePoints = null;
    _strokePoints = null;
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
    final committedPoints = _strokePoints;
    _strokePoints = null;

    if (!wasActive) return;
    if (committedPoints == null || committedPoints.isEmpty) return;
    if (_channelId == null) return;

    final tool = state.selectedTool;
    final kind = strokeKindForTool(tool);
    final isEraser = kind == StrokeKind.eraser;
    final stroke = CanvasStroke(
      id: newCanvasId(),
      color: isEraser ? '#00000000' : colorToHex(state.currentColor),
      width: _effectiveStrokeWidth(kind),
      points: List<CanvasPoint>.from(committedPoints),
      kind: kind,
    );

    // Append locally.
    final newStrokes = List<CanvasStroke>.from(state.strokes)..add(stroke);
    // `activePoints` is intentionally kept empty here — the field is
    // deprecated for in-flight rendering (see ActiveStrokeNotifier) but
    // is still part of the CanvasState shape for backwards-compat with
    // any external consumer reading it. Pin it to const [] so a stale
    // reader sees the canonical empty value.
    state = state.copyWith(strokes: newStrokes, activePoints: const []);
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
  // Wire format (coord_v: 2): {window_id, x_norm, y_norm, w_norm, h_norm,
  // coord_v: 2} where each _norm is in [0.0, 1.0] of the sender's
  // interactive viewport. Receivers multiply by their own viewport size
  // before applying. A 120 px minimum is enforced on receive so small
  // phone viewports don't collapse windows below readable size.
  //
  // Legacy payloads (coord_v absent or 1) contain raw CSS pixels
  // {window_id, x, y, width, height} and are passed through unchanged —
  // the LayoutBuilder in screen_share.dart clamps them on render.
  //
  // See docs/voice-lounge/01-coordinate-policy.md for the full decision.
  // -------------------------------------------------------------------------

  /// Throttle timer for screen-share window broadcasts (~20 fps).
  Timer? _screenShareThrottle;
  ScreenShareWindow? _pendingScreenShare;

  /// Viewport size used for the last queued throttled broadcast. Kept in
  /// sync with the [viewportSize] passed to [moveScreenShare].
  Size? _pendingScreenShareViewport;

  /// Builds a normalized-coord `screenshare_move` payload (coord_v: 2).
  /// Returns null when [viewportSize] is unavailable or zero — caller must
  /// short-circuit without emitting garbage.
  Map<String, dynamic>? _buildNormalizedPayload({
    required String windowId,
    required double x,
    required double y,
    required double width,
    required double height,
    required Size? viewportSize,
  }) {
    final vp = viewportSize;
    if (vp == null || vp.width <= 0 || vp.height <= 0) return null;
    return {
      'window_id': windowId,
      'x_norm': (x / vp.width).clamp(0.0, 1.0),
      'y_norm': (y / vp.height).clamp(0.0, 1.0),
      'w_norm': (width / vp.width).clamp(0.0, 1.0),
      'h_norm': (height / vp.height).clamp(0.0, 1.0),
      'coord_v': 2,
    };
  }

  /// Called while the user drags a screen-share window. Updates local
  /// state immediately and queues a throttled WS broadcast.
  ///
  /// [viewportSize] is the lounge's InteractiveViewer region as reported
  /// by its LayoutBuilder. Pass null only if the viewport is not yet
  /// measured — the broadcast will be suppressed rather than emitting
  /// stale raw pixels.
  void moveScreenShare({
    required String windowId,
    required double x,
    required double y,
    required double width,
    required double height,
    Size? viewportSize,
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
    _pendingScreenShareViewport = viewportSize;
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
    final payload = _buildNormalizedPayload(
      windowId: pending.windowId,
      x: pending.x,
      y: pending.y,
      width: pending.width,
      height: pending.height,
      viewportSize: _pendingScreenShareViewport,
    );
    if (payload == null) return; // viewport not yet measured — skip
    _sendCanvasEvent('screenshare_move', payload);
  }

  /// Called when the user releases a screen-share window drag/resize —
  /// flushes the pending broadcast immediately.
  ///
  /// [viewportSize] is the lounge's InteractiveViewer region. When null
  /// (lounge not yet measured) the broadcast is suppressed.
  void commitScreenShareMove({
    required String windowId,
    required double x,
    required double y,
    required double width,
    required double height,
    Size? viewportSize,
  }) {
    _screenShareThrottle?.cancel();
    _screenShareThrottle = null;
    _pendingScreenShare = null;
    _pendingScreenShareViewport = null;

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

    final payload = _buildNormalizedPayload(
      windowId: windowId,
      x: x,
      y: y,
      width: width,
      height: height,
      viewportSize: viewportSize,
    );
    if (payload == null) return; // viewport not yet measured — skip
    _sendCanvasEvent('screenshare_move', payload);
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
        final resolved = _resolveScreenShareMove(payload);
        if (resolved == null) return;
        final updated = Map<String, ScreenShareWindow>.from(
          state.screenSharePositions,
        );
        updated[resolved.windowId] = resolved;
        state = state.copyWith(screenSharePositions: updated);
    }
  }

  // -------------------------------------------------------------------------
  // Canvas authority
  // -------------------------------------------------------------------------

  /// Returns true when this device is allowed to send canvas events.
  ///
  /// A device may write when:
  /// - No authority has been claimed yet (null → first writer wins); OR
  /// - This device IS the current authority.
  ///
  /// When false the caller should skip the WS send (server drops it anyway;
  /// early exit saves the round-trip and honestly reflects read-only state).
  bool _canIWrite() {
    final cid = _channelId;
    if (cid == null) return false;
    final authority = ref.read(canvasAuthorityNotifierProvider(cid));
    if (authority == null) return true;
    final myDeviceId = ref.read(cryptoServiceProvider).deviceId;
    return authority == myDeviceId;
  }

  /// Emit a `canvas_authority_claim` event so the server grants this device
  /// the canvas write lock for [channelId]. The server's 1-second grace period
  /// prevents rapid back-and-forth between devices.
  void sendCanvasAuthorityClaim(String channelId) {
    ref
        .read(websocketProvider.notifier)
        .sendCanvasEvent(
          channelId: channelId,
          kind: 'canvas_authority_claim',
          payload: const {},
        );
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
  // -------------------------------------------------------------------------
  // Local viewport size (receiver side)
  //
  // The lounge screen pushes its InteractiveViewer region here so the
  // inbound screenshare_move handler can de-normalize coord_v:2 payloads
  // using the local device's viewport. Updated every time LayoutBuilder
  // reports a new size; null until first measurement.
  // -------------------------------------------------------------------------

  /// The local InteractiveViewer size, updated by [setViewportSize].
  Size? _localViewportSize;

  /// Called by the lounge screen whenever its LayoutBuilder measures a new
  /// InteractiveViewer region. Updates the local viewport used for both
  /// sender normalization (via the explicit [viewportSize] param on
  /// [moveScreenShare] / [commitScreenShareMove]) and receiver
  /// de-normalization of inbound coord_v:2 payloads.
  void setViewportSize(Size size) {
    if (size.width > 0 && size.height > 0) {
      _localViewportSize = size;
    }
  }

  /// Resolves an inbound `screenshare_move` payload to a [ScreenShareWindow]
  /// in local CSS pixels, or returns null if the payload is malformed.
  ///
  /// - coord_v: 2 → de-normalize using [_localViewportSize]; enforce 120 px min.
  /// - legacy (no coord_v or coord_v: 1) → use raw x/y/width/height unchanged.
  ScreenShareWindow? _resolveScreenShareMove(Map<String, dynamic> payload) {
    const double kMinWindowPx = 120.0;
    final windowId = payload['window_id'] as String?;
    if (windowId == null || windowId.isEmpty) return null;

    final coordV = payload['coord_v'] as int?;
    if (coordV == 2) {
      return _resolveNormalizedScreenShare(payload, windowId, kMinWindowPx);
    }
    return _resolveLegacyScreenShare(payload, windowId);
  }

  ScreenShareWindow? _resolveNormalizedScreenShare(
    Map<String, dynamic> payload,
    String windowId,
    double minPx,
  ) {
    final xNorm = (payload['x_norm'] as num?)?.toDouble();
    final yNorm = (payload['y_norm'] as num?)?.toDouble();
    if (xNorm == null || yNorm == null) return null;
    final vp = _localViewportSize;
    if (vp == null || vp.width <= 0 || vp.height <= 0) return null;
    final wNorm = (payload['w_norm'] as num?)?.toDouble() ?? 0.0;
    final hNorm = (payload['h_norm'] as num?)?.toDouble() ?? 0.0;
    return ScreenShareWindow(
      windowId: windowId,
      x: xNorm * vp.width,
      y: yNorm * vp.height,
      width: (wNorm * vp.width).clamp(minPx, double.infinity),
      height: (hNorm * vp.height).clamp(minPx, double.infinity),
    );
  }

  ScreenShareWindow? _resolveLegacyScreenShare(
    Map<String, dynamic> payload,
    String windowId,
  ) {
    final x = (payload['x'] as num?)?.toDouble();
    final y = (payload['y'] as num?)?.toDouble();
    if (x == null || y == null) return null;
    final existing = state.screenSharePositions[windowId];
    final w =
        (payload['width'] as num?)?.toDouble() ?? existing?.width ?? 320.0;
    final h =
        (payload['height'] as num?)?.toDouble() ?? existing?.height ?? 180.0;
    return ScreenShareWindow(
      windowId: windowId,
      x: x,
      y: y,
      width: w,
      height: h,
    );
  }

  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  void debugFlushStrokePoints() => _flushStrokePoints();

  @visibleForTesting
  bool get debugIsStrokeActive => _strokeActive;

  @visibleForTesting
  int get debugDragId => _dragId;

  /// Read-only view of the in-flight stroke's accumulated points (formerly
  /// `state.activePoints`). Exposed for tests that assert mid-drag
  /// state — production code reads in-flight points from
  /// `ActiveStrokeNotifier` instead.
  @visibleForTesting
  List<CanvasPoint> get debugStrokePoints =>
      _strokePoints == null ? const [] : List.unmodifiable(_strokePoints!);

  // ---------------------------------------------------------------------------
  // Dev-mode budget guard
  //
  // Fires a warning log when paint_p99 crosses 2× budget (32 ms) for 5+
  // consecutive calls.  Not an assert and not fatal — purely visibility.
  // Only active in kDebugMode so release builds pay zero cost.
  // ---------------------------------------------------------------------------

  /// Number of consecutive [continueStroke] calls whose elapsed time was
  /// recorded after the p99 exceeded 32 ms.  Resets whenever p99 drops
  /// back under budget.
  int _consecutiveOverBudget = 0;

  void _warnIfPerfDegraded() {
    if (!kDebugMode) return;
    final snap = CanvasPerf.snapshot();
    const double kBudgetWarnMs = 32.0; // 2× the 16 ms budget
    const int kWarnAfterCount = 5;
    if (snap.paintP99Ms > kBudgetWarnMs) {
      _consecutiveOverBudget++;
      if (_consecutiveOverBudget == kWarnAfterCount) {
        DebugLogService.instance.log(
          LogLevel.warning,
          'CanvasPerf',
          '[canvas-perf] paint p99 exceeded 2× budget: ${snap.toString()}',
        );
      }
    } else {
      _consecutiveOverBudget = 0;
    }
  }

  /// The most recent local InteractiveViewer region pushed via [setViewportSize].
  /// Read by [screen_share.dart] to pass as the [viewportSize] argument to
  /// [moveScreenShare] / [commitScreenShareMove] without threading the Size
  /// through the widget tree.
  Size? get localViewportSize => _localViewportSize;

  @visibleForTesting
  Size? get debugLocalViewportSize => _localViewportSize;

  void _sendCanvasEvent(String kind, Map<String, dynamic> payload) {
    final cid = _channelId;
    if (cid == null) return;
    if (!_canIWrite()) return;

    ref
        .read(websocketProvider.notifier)
        .sendCanvasEvent(channelId: cid, kind: kind, payload: payload);
  }
}

/// Back-compat alias: existing call sites still refer to `canvasProvider`.
/// The class is named `CanvasController` to avoid shadowing dart:ui.Canvas
/// inside this library.
final canvasProvider = canvasControllerProvider;
