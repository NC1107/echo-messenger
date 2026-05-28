import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/canvas_models.dart'
    show CanvasState, CanvasTool, kCanvasHeight, kCanvasWidth;
import '../providers/auth_provider.dart';
import '../providers/canvas_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_lounge_background_provider.dart';
import '../providers/voice_lounge_fullscreen_provider.dart';
import '../providers/voice_lounge_view_mode_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../services/debug_log_service.dart';
import '../services/pip_controller.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/canvas_utils.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/echo_bottom_sheet.dart';
import '../widgets/lounge_drawing_canvas.dart';
import '../widgets/voice_lounge/encrypted_canvas_notice.dart';
import '../widgets/vertex_mesh_background.dart';
import '../widgets/voice_canvas.dart';
import 'voice_lounge/call_metrics_chip.dart';
import 'voice_lounge/dock_submenus.dart';
import 'voice_lounge/drawing_tools_menu.dart';
import 'voice_lounge/floating_dock.dart';
import 'voice_lounge/lounge_constants.dart';
import 'voice_lounge/lounge_header.dart';
import 'voice_lounge/participant_grid.dart';
import 'voice_lounge/screen_share.dart';

/// Half the default avatar-tile diameter in canvas-space pixels — used
/// when growing the auto-fit bbox so an avatar's edge (not just its
/// centre) lands inside the framed region. Mirrors the `_kAvatarSize`
/// constant inside `voice_canvas.dart`; duplicated here to avoid a
/// cross-widget export of a render constant.
const double _kAvatarTileRadius = 24.0;

/// Canvas-space radius of the default avatar ring used by
/// `voice_canvas.dart`'s `_defaultAvatarPos` when no one has dragged
/// their puck yet. Default positions sit on a circle of this radius
/// around the canvas centre; the initial-pose fallback zooms out far
/// enough to frame that entire ring so a fresh joiner sees every
/// participant (including their own avatar) without panning across
/// 50 000 canvas-pixels first. Mirrors the `0.3 * kCanvasWidth`
/// magic number in `_defaultAvatarPos`; kept in sync with that
/// helper by the `voice_canvas` widget tests.
const double _kDefaultAvatarRingRadius = 0.3 * kCanvasWidth;

/// Returns a new transform that scales the lounge canvas to
/// [targetScale] while keeping the canvas-space point currently under
/// [tapPoint] (in InteractiveViewer-region-local pixels) anchored to
/// the same viewport pixel — i.e. the user's tap stays under their
/// finger.
///
/// The transform `T` maps canvas-space points to viewport-space
/// points. For a point `p` under the tap, `T(p) = tapPoint`, so
/// `p = T⁻¹(tapPoint)`. The output `T'` is constructed so that
/// `T'(p) = tapPoint` at `scale = targetScale`:
///
///   T'.x = s · p.x + tx   where   tx = tapPoint.dx − s · p.x
///   T'.y = s · p.y + ty   where   ty = tapPoint.dy − s · p.y
///
/// Exposed as a top-level function so the math is unit-testable
/// without spinning up a full lounge widget tree.
@visibleForTesting
Matrix4 zoomAroundPoint({
  required Matrix4 current,
  required Offset tapPoint,
  required double targetScale,
}) {
  final inverse = Matrix4.copy(current)..invert();
  final canvasPoint = MatrixUtils.transformPoint(inverse, tapPoint);
  return Matrix4.identity()
    ..scaleByDouble(targetScale, targetScale, targetScale, 1)
    ..setTranslationRaw(
      tapPoint.dx - canvasPoint.dx * targetScale,
      tapPoint.dy - canvasPoint.dy * targetScale,
      0,
    );
}

/// Discord-style voice lounge that replaces the chat content area when the
/// user is in a voice call and chooses to view the lounge.
/// Voice lounge screen. The hide-members toggle in the header actually
/// controls the HomeScreen's right-side group-members panel (the "Owner /
/// Members" sidebar visible to the right of the lounge), not the
/// participant grid inside the lounge itself.
class VoiceLoungeScreen extends ConsumerStatefulWidget {
  /// Called when the user taps "Back to chat".
  final VoidCallback? onBackToChat;

  /// Current visibility of the right-side group-members panel.  Owned by
  /// HomeScreen, threaded through so the lounge header eye-icon shows the
  /// correct state.
  final bool membersPanelVisible;

  /// Called when the lounge-header eye-icon is tapped.  HomeScreen flips
  /// its own `_showMembers` flag in response.
  final VoidCallback? onToggleMembersPanel;

  const VoiceLoungeScreen({
    super.key,
    this.onBackToChat,
    this.membersPanelVisible = true,
    this.onToggleMembersPanel,
  });

  @override
  ConsumerState<VoiceLoungeScreen> createState() => _VoiceLoungeScreenState();
}

class _VoiceLoungeScreenState extends ConsumerState<VoiceLoungeScreen> {
  /// Key of the tile currently in focus. Null = grid / auto-spotlight view.
  /// Format: 'local', 'remote-{sid}', 'screenshare-local', 'screenshare-{sid}'.
  String? _focusedTileKey;

  /// Whether the drawing canvas overlay is active.
  bool _isDrawing = false;

  // Members-panel collapse state lives on HomeScreen; this widget only
  // forwards the toggle. See [VoiceLoungeScreen.onToggleMembersPanel].

  /// Anchors for dock submenu panels.
  final LayerLink _drawingToolsLayerLink = LayerLink();
  final LayerLink _micLayerLink = LayerLink();
  final LayerLink _cameraLayerLink = LayerLink();
  final LayerLink _screenShareLayerLink = LayerLink();

  /// Which dock submenu is currently open (null = none).
  DockSubmenu? _activeSubmenu;

  // Spotlight vs canvas selection lives in voiceLoungeViewModeProvider
  // so toggling fullscreen (which remounts this widget at a different
  // Row index in HomeScreen's layout) doesn't snap us back to spotlight.
  // See lib/src/providers/voice_lounge_view_mode_provider.dart.
  bool get _spotlightMode =>
      ref.watch(voiceLoungeViewModeProvider) == VoiceLoungeView.spotlight;

  /// Pan + zoom controller for the canvas. Identity = 1x, no offset.
  /// The lounge background sits OUTSIDE this transform so zoom/pan only
  /// moves the canvas content (Figma-style); the bg stays fixed.
  late final TransformationController _viewport;

  /// Visibility flag for the reset-view button. Tracks whether the
  /// transform differs from identity (any zoom or pan applied).
  bool _viewportTransformed = false;

  /// True once the viewport has been initialised to the auto-fit-content
  /// pose. Reset to false when this widget is rebuilt for a different
  /// conversation/channel so each lounge session starts from a clean
  /// canvas overview.
  bool _viewportInitialised = false;

  /// Tracks the actual InteractiveViewer region (from LayoutBuilder
  /// constraints) so listener-driven callbacks like [_onViewportChanged]
  /// + [_resetViewport] + [_toggleDoubleTapZoom] use the same dimensions
  /// the initial pose was computed against. MediaQuery.sizeOf would
  /// over-count by the header band + dock + members panel on tablets
  /// and desktops, leaving reset/double-tap landing in the wrong pose.
  Size? _interactiveViewportSize;

  /// Captured at initState so dispose() can clear fullscreen without
  /// touching `ref` (which becomes invalid the moment the element is
  /// unmounted, even before super.dispose runs). Riverpod's
  /// StateController survives across rebuilds and is safe to retain.
  late final StateController<bool> _fullscreenNotifier;

  @override
  void initState() {
    super.initState();
    _viewport = TransformationController()..addListener(_onViewportChanged);
    _fullscreenNotifier = ref.read(voiceLoungeFullscreenProvider.notifier);
    // Breadcrumb fires post-joinChannel: missing = crash in joinChannel; present-but-alone = crash in build.
    final voiceLk = ref.read(livekitVoiceProvider);
    DebugLogService.instance.log(
      LogLevel.info,
      'VoiceLoungeUI',
      'VoiceLoungeScreen mounted '
          'channelId=${voiceLk.channelId ?? "none"} '
          'conversationId=${voiceLk.conversationId ?? "none"}',
    );
    DebugLogService.instance.forceFlush().ignore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final convId = ref.read(livekitVoiceProvider).conversationId;
      if (convId == null || convId.isEmpty) return;
      final conv = ref
          .read(conversationsProvider)
          .conversations
          .where((c) => c.id == convId)
          .firstOrNull;
      if (conv == null) return;
      EncryptedCanvasNotice.maybeShow(context, isEncrypted: conv.isEncrypted);
    });
  }

  @override
  void dispose() {
    _viewport
      ..removeListener(_onViewportChanged)
      ..dispose();
    // Clear fullscreen so the user doesn't return to an immersive
    // HomeScreen the next time they open the lounge. Uses the notifier
    // captured at initState — ref is unsafe in dispose().
    if (_fullscreenNotifier.state) _fullscreenNotifier.state = false;
    DebugLogService.instance.log(
      LogLevel.info,
      'VoiceLoungeUI',
      'VoiceLoungeScreen disposed',
    );
    super.dispose();
  }

  void _onViewportChanged() {
    // Show the reset-view affordance whenever the user is no longer at
    // the auto-fit pose (either scale or translation differs by more
    // than a tolerance). Uses the actual InteractiveViewer constraints
    // captured by the LayoutBuilder — MediaQuery.sizeOf would over-count
    // by the header band + dock + members panel.
    final size = _interactiveViewportSize;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    final fitPose = _computeInitialPose(ref.read(canvasProvider), size);
    final fitScale = fitPose.getMaxScaleOnAxis();
    final fitTranslation = fitPose.getTranslation();
    final cur = _viewport.value;
    final scaleDiff = (cur.getMaxScaleOnAxis() - fitScale).abs();
    final translationDiff = (cur.getTranslation() - fitTranslation).length;
    // Tolerances: scale within 0.1% of fit, translation within 0.5 px.
    final transformed = scaleDiff > fitScale * 1e-3 || translationDiff > 0.5;
    if (transformed != _viewportTransformed) {
      setState(() => _viewportTransformed = transformed);
    }
  }

  /// Toggle drawing mode from the dock's pencil button. When turning OFF,
  /// also resets `selectedTool` to `CanvasTool.none` — otherwise the
  /// auto-enable watch in `build()` (which flips `_isDrawing = true`
  /// whenever a non-none tool is selected) immediately re-enables
  /// drawing, leaving the user with no way to exit drawing mode (user
  /// feedback 2026-05-28).
  void _toggleDrawingMode() {
    final wasDrawing = _isDrawing;
    setState(() => _isDrawing = !wasDrawing);
    if (wasDrawing) {
      // Exiting drawing mode — clear the tool so the build watch doesn't
      // immediately auto-re-enable on the next frame.
      ref.read(canvasProvider.notifier).setTool(CanvasTool.none);
    }
  }

  void _resetViewport() {
    // Recompute the same auto-fit pose used on first mount so the user
    // can always get back to "looking at the existing content". Uses
    // the actual InteractiveViewer region (captured by LayoutBuilder)
    // so the reset lands in the right place on any device — tablets +
    // desktops include sidebars / members panel that MediaQuery
    // doesn't subtract.
    final size = _interactiveViewportSize;
    if (size == null || size.width <= 0 || size.height <= 0) {
      _viewport.value = Matrix4.identity();
      return;
    }
    _viewport.value = _computeInitialPose(ref.read(canvasProvider), size);
  }

  /// Compute the matrix that frames the existing canvas content inside
  /// [viewport]. Auto-fit semantics:
  ///   - Bounding box of every stroke point + image rect + avatar tile.
  ///   - +10% padding so content doesn't touch the edges.
  ///   - Empty canvas (no strokes / images / avatars) → centre on the
  ///     middle of the canvas at a zoom that frames the default avatar
  ///     ring so a fresh joiner sees every participant without first
  ///     panning across the 100k×100k surface (#1265).
  ///
  /// Avatars ARE included so a fresh joiner with no drawings still
  /// frames participants in view; the per-audio-tick avatar jitter
  /// can't pull the fit pose around because the listener-driven
  /// helpers only recompute on viewport-transform changes, not on
  /// canvas-state updates.
  Matrix4 _computeInitialPose(CanvasState canvas, Size viewport) {
    final bbox = _contentBbox(canvas);
    if (bbox == null) {
      return _centeredPose(viewport);
    }
    final contentW = bbox.width;
    final contentH = bbox.height;
    // 10% padding around the bbox so strokes don't kiss the edges.
    final pad = math.max(contentW, contentH) * 0.1;
    final paddedW = contentW + pad * 2;
    final paddedH = contentH + pad * 2;
    final fit = math.min(viewport.width / paddedW, viewport.height / paddedH);
    // Anchor: bbox top-left lands at (-pad, -pad) of the visible region
    // so the padding shows on every side.
    return Matrix4.identity()
      ..scaleByDouble(fit, fit, fit, 1)
      ..setTranslationRaw(-(bbox.left - pad) * fit, -(bbox.top - pad) * fit, 0);
  }

  /// Returns the bounding rectangle of every stroke point, image rect,
  /// and stored avatar position, or null when the canvas has no content
  /// to fit around. Avatars are inflated by [_kAvatarTileRadius] so the
  /// tile (not just its centre) fits inside the frame.
  Rect? _contentBbox(CanvasState canvas) {
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final s in canvas.strokes) {
      for (final p in s.points) {
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
      }
    }
    for (final img in canvas.images) {
      if (img.x < minX) minX = img.x;
      if (img.y < minY) minY = img.y;
      if (img.x + img.width > maxX) maxX = img.x + img.width;
      if (img.y + img.height > maxY) maxY = img.y + img.height;
    }
    for (final pos in canvas.avatarPositions.values) {
      final half = _kAvatarTileRadius * pos.scale;
      if (pos.x - half < minX) minX = pos.x - half;
      if (pos.y - half < minY) minY = pos.y - half;
      if (pos.x + half > maxX) maxX = pos.x + half;
      if (pos.y + half > maxY) maxY = pos.y + half;
    }
    if (minX == double.infinity || maxX <= minX || maxY <= minY) {
      return null;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Pose used when the canvas is completely empty (no strokes, no
  /// images, no persisted avatar drags). Centres on the canvas middle
  /// and zooms OUT just far enough to frame the default avatar ring
  /// `voice_canvas.dart` lays out for un-dragged participants — so a
  /// fresh joiner sees every avatar (their own included) without
  /// hunting across the 100k×100k surface (#1265). A 10% margin keeps
  /// pucks off the very edge of the viewport.
  Matrix4 _centeredPose(Size viewport) {
    const cx = kCanvasWidth / 2;
    const cy = kCanvasHeight / 2;
    // Frame the full default avatar ring + half an avatar tile so the
    // outermost puck lands inside the visible region, then a 10%
    // padding band on top.
    const ringExtent = _kDefaultAvatarRingRadius + _kAvatarTileRadius;
    const framed = ringExtent * 2 * 1.1;
    final fit = math.min(viewport.width, viewport.height) / framed;
    return Matrix4.identity()
      ..scaleByDouble(fit, fit, fit, 1)
      ..setTranslationRaw(
        viewport.width / 2 - cx * fit,
        viewport.height / 2 - cy * fit,
        0,
      );
  }

  /// Toggle between auto-fit and a 2× zoom centred on the tap point.
  /// `tapPoint` is viewport-local pixels.
  void _toggleDoubleTapZoom(Offset tapPoint) {
    final current = _viewport.value.getMaxScaleOnAxis();
    final size = _interactiveViewportSize ?? Size.zero;
    final fitPose = _computeInitialPose(ref.read(canvasProvider), size);
    final fitScale = fitPose.getMaxScaleOnAxis();
    final isAtFit = (current - fitScale).abs() < 1e-3;
    if (isAtFit) {
      // Zoom in 2× anchored on the tap point.
      _viewport.value = zoomAroundPoint(
        current: _viewport.value,
        tapPoint: tapPoint,
        targetScale: 2.0,
      );
    } else {
      _viewport.value = fitPose;
    }
  }

  String? _buildAvatarUrl() {
    final avatarPath = ref.read(authProvider).avatarUrl;
    if (avatarPath == null || avatarPath.isEmpty) return null;
    final serverUrl = ref.read(serverUrlProvider);
    return '$serverUrl$avatarPath';
  }

  static bool _hasActiveScreenShare(lk.Room? room) {
    if (room == null) return false;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (pub.track != null &&
            pub.source == lk.TrackSource.screenShareVideo) {
          return true;
        }
      }
    }
    return false;
  }

  /// Find a remote participant by SID and return their first track matching
  /// [source], or null.
  static lk.VideoTrack? _findRemoteTrack(
    lk.Room room,
    String sid,
    lk.TrackSource source,
  ) {
    final participant = room.remoteParticipants.values
        .where((p) => p.sid.toString() == sid)
        .firstOrNull;
    if (participant == null) return null;
    final pub = participant.videoTrackPublications
        .where((p) => p.track != null && p.source == source)
        .firstOrNull;
    return pub?.track as lk.VideoTrack?;
  }

  /// Resolve a tile key to the matching [VideoTrack] and a mirror flag.
  ///
  /// Keys: 'local', 'remote-{sid}', 'screenshare-local', 'screenshare-{sid}'.
  (lk.VideoTrack?, bool) _resolveTrack(
    lk.Room? room,
    LiveKitVoiceState voiceLk,
    String tileKey,
  ) {
    if (room == null) return (null, false);
    if (tileKey == 'local') {
      final pub = room.localParticipant?.videoTrackPublications
          .where((p) => p.track != null && p.source == lk.TrackSource.camera)
          .firstOrNull;
      if (pub == null || !voiceLk.isVideoEnabled) return (null, false);
      return (pub.track as lk.VideoTrack?, true);
    }
    if (tileKey == kScreenshareLocal) {
      final pub = room.localParticipant?.videoTrackPublications
          .where(
            (p) =>
                p.track != null && p.source == lk.TrackSource.screenShareVideo,
          )
          .firstOrNull;
      return (pub?.track as lk.VideoTrack?, false);
    }
    if (tileKey.startsWith('screenshare-')) {
      final sid = tileKey.substring('screenshare-'.length);
      return (
        _findRemoteTrack(room, sid, lk.TrackSource.screenShareVideo),
        false,
      );
    }
    if (tileKey.startsWith('remote-')) {
      final sid = tileKey.substring('remote-'.length);
      return (_findRemoteTrack(room, sid, lk.TrackSource.camera), false);
    }
    return (null, false);
  }

  void _openFullscreen(BuildContext ctx, lk.VideoTrack track, bool mirror) {
    Navigator.of(ctx, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => FullscreenVideoPage(track: track, mirror: mirror),
      ),
    );
  }

  List<Widget> _buildRemoteShareWindows(lk.Room room) {
    final windows = <Widget>[];
    var idx = 0;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (pub.track != null &&
            pub.track is lk.VideoTrack &&
            pub.source == lk.TrackSource.screenShareVideo) {
          final track = pub.track! as lk.VideoTrack;
          final sid = p.sid.toString();
          final name = participantDisplayName(p);
          windows.add(
            DraggableScreenShareWindow(
              key: ValueKey('remote-share-$sid'),
              initialRight: 16.0 + idx * 30,
              initialTop: 16.0 + idx * 30,
              label: "$name's screen",
              isLocal: false,
              // Stable id so every participant updates the same entry
              // in CanvasState.screenSharePositions when anyone drags
              // this window.
              windowId: 'screenshare-$sid',
              // Builder form so the window reshapes itself to match the
              // remote source — a phone share comes in portrait, not
              // 16:9.
              childBuilder: (ctx, aspect) => GestureDetector(
                onDoubleTap: () =>
                    setState(() => _focusedTileKey = 'screenshare-$sid'),
                child: AspectAwareVideoTrack(
                  track: track,
                  aspectRatio: aspect,
                  fit: lk.VideoViewFit.contain,
                ),
              ),
            ),
          );
          idx++;
        }
      }
    }
    return windows;
  }

  /// Small overlay badge used instead of a full header in landscape mode.
  Widget _buildHeaderBadge(
    BuildContext context,
    String channelName,
    int participantCount,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onBackToChat != null)
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to chat',
            onPressed: widget.onBackToChat,
            color: Colors.white,
            iconSize: 20,
            style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.graphic_eq, size: 14, color: EchoTheme.online),
              const SizedBox(width: 6),
              Text(
                channelName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '· $participantCount',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Dispatches to focused view, auto-spotlight, or the interactive canvas.
  Widget _buildContentArea({
    required lk.Room? room,
    required LiveKitVoiceState voiceLk,
    required ScreenShareState screenShare,
    required Map<String, String?> memberAvatars,
  }) {
    if (_focusedTileKey != null) {
      return _buildFocusedView(
        room: room,
        voiceLk: voiceLk,
        screenShare: screenShare,
        memberAvatars: memberAvatars,
      );
    }

    final hasRemoteShare = _hasActiveScreenShare(room);

    // Default: voice-lounge canvas (movable avatars + drawing + images).
    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId ?? '';

    // Spotlight mode: show participant grid with camera tiles
    if (_spotlightMode) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (screenShare.isScreenSharing) ...[
              GestureDetector(
                onTap: () =>
                    setState(() => _focusedTileKey = kScreenshareLocal),
                child: const ScreenShareViewer(),
              ),
              const SizedBox(height: 16),
            ],
            ParticipantGrid(
              room: room,
              voiceState: voiceLk,
              localAvatarUrl: _buildAvatarUrl(),
              memberAvatars: memberAvatars,
              authToken: ref.read(authProvider).token,
              onTileTap: (key) => setState(() => _focusedTileKey = key),
            ),
          ],
        ),
      );
    }

    if (conversationId.isNotEmpty && channelId.isNotEmpty) {
      return Stack(
        children: [
          VoiceCanvas(
            channelId: channelId,
            conversationId: conversationId,
            room: room,
            voiceState: voiceLk,
            localAvatarUrl: _buildAvatarUrl(),
            onVideoDoubleTap: (track, mirror) =>
                _openFullscreen(context, track, mirror),
          ),
          // Remote screen shares (floating, draggable, resizable)
          if (hasRemoteShare && room != null) ..._buildRemoteShareWindows(room),
          // Local screen-share preview (floating, tap to focus)
          if (screenShare.isScreenSharing)
            DraggableScreenShareWindow(
              key: const ValueKey('local-share'),
              initialRight: 16,
              initialTop: 16,
              label: 'Your screen',
              isLocal: true,
              // Per-participant id so two concurrent sharers don't
              // overwrite each other's local-preview positions in the
              // shared canvas state (audit Finding 2, 2026-05-28). The
              // local key (kScreenshareLocal) is still used for the
              // *focus-tile* state because that's a per-client UI
              // selection, not a synced canvas object.
              windowId:
                  '$kScreenshareLocal-${ref.read(authProvider).userId ?? "anon"}',
              // Builder form so the window matches a portrait phone
              // share instead of letterboxing it into landscape.
              childBuilder: (ctx, aspect) => GestureDetector(
                onDoubleTap: () =>
                    setState(() => _focusedTileKey = kScreenshareLocal),
                child: LocalScreenShareTrack(ref: ref, aspectRatio: aspect),
              ),
            ),
        ],
      );
    }

    // Fallback grid (no channelId, e.g. direct-call without a channel)
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (screenShare.isScreenSharing)
            GestureDetector(
              onTap: () => setState(() => _focusedTileKey = kScreenshareLocal),
              child: const ScreenShareViewer(),
            ),
          if (screenShare.isScreenSharing) const SizedBox(height: 16),
          ParticipantGrid(
            room: room,
            voiceState: voiceLk,
            localAvatarUrl: _buildAvatarUrl(),
            memberAvatars: memberAvatars,
            authToken: ref.read(authProvider).token,
            onTileTap: (key) => setState(() => _focusedTileKey = key),
          ),
        ],
      ),
    );
  }

  /// Focused layout: the tapped stream fills the content area with a
  /// thumbnail strip below and close / fullscreen overlay buttons.
  Widget _buildFocusedView({
    required lk.Room? room,
    required LiveKitVoiceState voiceLk,
    required ScreenShareState screenShare,
    required Map<String, String?> memberAvatars,
  }) {
    final tileKey = _focusedTileKey!;
    final (track, mirror) = _resolveTrack(room, voiceLk, tileKey);

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.black),
              if (track != null)
                lk.VideoTrackRenderer(
                  track,
                  fit: lk.VideoViewFit.contain,
                  mirrorMode: mirror
                      ? lk.VideoViewMirrorMode.mirror
                      : lk.VideoViewMirrorMode.off,
                )
              else
                const Center(
                  child: Icon(Icons.person, size: 64, color: Colors.white54),
                ),
              // Top-left: exit focus
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: 'Exit focus',
                  onPressed: () => setState(() => _focusedTileKey = null),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                    padding: const EdgeInsets.all(8),
                    minimumSize: const Size(44, 44),
                  ),
                ),
              ),
              // Top-right: fullscreen (only when video is playing)
              if (track != null)
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen, color: Colors.white),
                    tooltip: 'Fullscreen',
                    onPressed: () => _openFullscreen(context, track, mirror),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black45,
                      padding: const EdgeInsets.all(8),
                      minimumSize: const Size(44, 44),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // Thumbnail strip — tap any tile to switch focus
        SizedBox(
          height: 90,
          child: ParticipantGrid(
            room: room,
            voiceState: voiceLk,
            localAvatarUrl: _buildAvatarUrl(),
            memberAvatars: memberAvatars,
            compact: true,
            authToken: ref.read(authProvider).token,
            onTileTap: (key) => setState(() => _focusedTileKey = key),
          ),
        ),
      ],
    );
  }

  /// Picture-in-Picture body: scan remote participants for a screen-share
  /// track and render it edge-to-edge.  Returns null if no track is found
  /// so the caller can fall back to the regular layout.
  Widget? _buildPipBody(WidgetRef ref) {
    final room = ref.read(livekitVoiceProvider.notifier).room;
    if (room == null) return null;
    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.videoTrackPublications) {
        final lk.VideoTrack? track = pub.track;
        if (track != null &&
            pub.subscribed &&
            pub.source == lk.TrackSource.screenShareVideo) {
          return ColoredBox(
            color: Colors.black,
            child: lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain),
          );
        }
      }
    }
    return null;
  }

  /// Opens the system file picker, copies the chosen image into the app's
  /// document directory (so it survives package data clears that wipe the
  /// picker's temp cache), and persists the resolved path via
  /// [voiceLoungeBackgroundProvider].
  ///
  /// On web there is no [File] backing — we fall back to using the picker's
  /// returned `path` directly (typically a blob URL handled by [Image.network]
  /// — but on web the lounge background simply skips rendering because
  /// `dart:io`'s [File] is unavailable).  Mobile/desktop is the supported
  /// surface for MVP.
  Future<void> _pickBackground() async {
    String stage = 'open picker';
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        // User dismissed — not an error.
        return;
      }
      final picked = result.files.single;
      stage = 'read picked path';
      final srcPath = picked.path;
      if (srcPath == null || srcPath.isEmpty) {
        if (mounted) {
          ToastService.show(
            context,
            'Couldn’t read the picked file — try Browse files again.',
            type: ToastType.error,
          );
        }
        return;
      }

      stage = 'copy to documents dir';
      String resolved = srcPath;
      if (!kIsWeb) {
        try {
          final docs = await getApplicationDocumentsDirectory();
          final ext = p.extension(srcPath).isNotEmpty
              ? p.extension(srcPath)
              : '.img';
          final destName =
              'voice_lounge_bg_${DateTime.now().millisecondsSinceEpoch}$ext';
          final destPath = p.join(docs.path, destName);
          await File(srcPath).copy(destPath);
          resolved = destPath;
        } catch (e) {
          debugPrint('[VoiceLoungeScreen] copy background failed: $e');
          // Fall back to the original path; it may still load if the source
          // file is in a stable location (e.g. the user's own ~/Pictures).
          stage = 'fall back to source path';
        }
      }

      // Final guard: confirm the resolved path actually points at a readable
      // file before persisting. Without this we silently saved a dead path
      // and the background quietly didn't update on next render.
      if (!kIsWeb && !File(resolved).existsSync()) {
        if (mounted) {
          ToastService.show(
            context,
            'Picked file isn’t accessible (sandbox path). Try saving the '
            'image to your Documents folder and picking it again.',
            type: ToastType.error,
          );
        }
        return;
      }

      await ref
          .read(voiceLoungeBackgroundProvider.notifier)
          .setCustomBackgroundPath(resolved);

      if (mounted) {
        ToastService.show(
          context,
          'Lounge background updated.',
          type: ToastType.success,
        );
      }
    } catch (e) {
      debugPrint('[VoiceLoungeScreen] pick background failed at $stage: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Couldn’t set background ($stage): $e',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _clearBackground() async {
    await ref.read(voiceLoungeBackgroundProvider.notifier).clear();
  }

  /// Show a bottom-sheet with "Choose image" + "Reset to default" so the
  /// single icon button covers both operations. On desktop (600px+), shows
  /// a modal dialog with a grid of preset backgrounds instead.
  Future<void> _openBackgroundMenu(BuildContext ctx) async {
    final hasCustom =
        ref.read(voiceLoungeBackgroundProvider).customBackgroundPath != null;
    final isDesktop = MediaQuery.sizeOf(ctx).width >= 600;

    if (isDesktop) {
      await showDialog<void>(
        context: ctx,
        barrierDismissible: true,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: dialogCtx.surface,
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Voice lounge background'),
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  icon: Icon(
                    Icons.close,
                    size: 20,
                    color: dialogCtx.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: MediaQuery.sizeOf(dialogCtx).width.clamp(320.0, 440.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Custom image'),
                    onPressed: () {
                      Navigator.of(dialogCtx).pop();
                      _pickBackground();
                    },
                  ),
                  if (hasCustom) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.restore),
                      label: const Text('Remove image'),
                      onPressed: () {
                        Navigator.of(dialogCtx).pop();
                        _clearBackground();
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  Divider(height: 1, color: dialogCtx.border),
                  const SizedBox(height: 12),
                  const _VertexTunableControls(),
                ],
              ),
            ),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: dialogCtx.border),
          ),
        ),
      );
    } else {
      await showEchoBottomSheet<void>(
        ctx,
        builder: (sheetCtx) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('Choose voice lounge background'),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _pickBackground();
                  },
                ),
                if (hasCustom)
                  ListTile(
                    leading: const Icon(Icons.restore),
                    title: const Text('Remove image'),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _clearBackground();
                    },
                  ),
                const Divider(height: 1),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: _VertexTunableControls(),
                ),
              ],
            ),
          );
        },
      );
    }
  }

  /// Resolves the active background widget for the lounge.  When the user
  /// has picked a custom image AND the file still exists on disk, renders
  /// it as a [BoxFit.cover] backdrop with a 50% black overlay for legibility.
  /// Otherwise falls back to the original [VertexMeshBackground].
  Widget _buildBackground(BuildContext context) {
    final bg = ref.watch(voiceLoungeBackgroundProvider);
    final path = bg.customBackgroundPath;
    final vertexColor = bg.vertexColor ?? context.accent;
    final vertexCount = bg.vertexCount;
    final connectionDistance = bg.connectionDistance;
    if (customBackgroundFileExists(path)) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(path!),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => VertexMeshBackground(
              accentColor: vertexColor,
              backgroundColor: context.mainBg,
              vertexCount: vertexCount,
              connectionDistance: connectionDistance,
            ),
          ),
          const ColoredBox(color: Color(0x80000000)),
        ],
      );
    }
    return VertexMeshBackground(
      accentColor: vertexColor,
      backgroundColor: context.mainBg,
      vertexCount: vertexCount,
      connectionDistance: connectionDistance,
    );
  }

  /// True on iOS / Android — the touch-friendly platforms where the
  /// corner controls need a 44pt minimum hit target instead of the
  /// 34pt that's fine for desktop mouse pointers.
  bool get _isTouchPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Wraps an icon button payload in a tappable circle. On touch
  /// platforms the hit target is bumped to 44×44 (Apple HIG / Material
  /// minimum); desktop keeps the compact 34×34 size that the design
  /// originally shipped with.
  Widget _buildCornerControl({
    required String semanticLabel,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final double size = _isTouchPlatform ? 44 : 34;
    final double iconSize = _isTouchPlatform ? 22 : 18;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(icon, size: iconSize, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  /// Fullscreen-immersive toggle. Pressing this hides the HomeScreen
  /// sidebar / members panel / title bar and the lounge's own header,
  /// leaving only the canvas + dock. Pressing again restores them.
  Widget _buildFullscreenButton(BuildContext context) {
    final isFull = ref.watch(voiceLoungeFullscreenProvider);
    return _buildCornerControl(
      semanticLabel: isFull
          ? 'Exit fullscreen lounge'
          : 'Enter fullscreen lounge',
      icon: isFull ? Icons.fullscreen_exit : Icons.fullscreen,
      onTap: () =>
          ref.read(voiceLoungeFullscreenProvider.notifier).update((v) => !v),
    );
  }

  /// Reset-view affordance shown only when the canvas is zoomed or panned.
  /// Returns the canvas transform to identity (1x, no offset).
  Widget _buildResetViewButton(BuildContext context) {
    return _buildCornerControl(
      semanticLabel: 'Reset canvas zoom',
      icon: Icons.fit_screen_outlined,
      onTap: _resetViewport,
    );
  }

  /// Top-right "Clear board" affordance with a confirmation dialog.
  /// Wipes everyone's strokes + images. Lives outside the drawing menu
  /// because it's a destructive action that shouldn't share neighbours
  /// with the pen / color / size pickers.
  Widget _buildClearBoardButton(BuildContext context) {
    return _buildCornerControl(
      semanticLabel: 'Clear the canvas board for everyone',
      icon: Icons.delete_sweep_outlined,
      onTap: () => _confirmClearBoard(context),
    );
  }

  Future<void> _confirmClearBoard(BuildContext context) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Clear board?',
      content: Text(
        "This removes every drawing and image on the canvas for "
        'everyone in the call.',
        style: TextStyle(color: context.textSecondary, fontSize: 14),
      ),
      confirmLabel: 'Clear board',
      destructive: true,
    );
    if (!confirmed) return;
    ref.read(canvasProvider.notifier).clearDrawing();
  }

  /// Small circular icon button that opens the background-picker menu.  This
  /// is the ONE settings entry-point for the customizable voice-lounge
  /// background feature.
  Widget _buildBackgroundPickerButton(BuildContext context) {
    return _buildCornerControl(
      semanticLabel: 'Voice lounge background settings',
      icon: Icons.wallpaper,
      onTap: () => _openBackgroundMenu(context),
    );
  }

  void _closeSubmenu() => setState(() => _activeSubmenu = null);

  /// Resolves a relative or absolute avatar URL to a full URL.
  String _resolveAvatarUrl(String avatarUrl, String serverUrl) {
    return avatarUrl.startsWith('http') ? avatarUrl : '$serverUrl$avatarUrl';
  }

  /// Builds the username -> avatarUrl map from the active conversation's members.
  Map<String, String?> _buildMemberAvatars(String conversationId) {
    final serverUrl = ref.read(serverUrlProvider);
    final conversations = ref.watch(conversationsProvider).conversations;
    final conversation = conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final avatars = <String, String?>{};
    if (conversation == null) return avatars;
    for (final m in conversation.members) {
      final resolvedUrl = m.avatarUrl != null && m.avatarUrl!.isNotEmpty
          ? _resolveAvatarUrl(m.avatarUrl!, serverUrl)
          : null;
      avatars[m.username] = resolvedUrl;
    }
    return avatars;
  }

  /// Shared scaffold: [Listener] + [Container] + [ClipRect] + [Stack].
  /// [layers] are inserted into the [Stack] in order.
  Widget _buildLoungeScaffold(BuildContext context, List<Widget> layers) {
    return Listener(
      onPointerDown: (e) {
        if (e.buttons == kSecondaryButton && _isDrawing) {
          setState(() => _isDrawing = false);
        }
      },
      child: Container(
        color: context.mainBg,
        child: ClipRect(child: Stack(children: layers)),
      ),
    );
  }

  /// Landscape layout: floating badge instead of header bar.
  Widget _buildLandscapeLayout(
    BuildContext context,
    Widget contentArea,
    Widget dock,
    String conversationId,
    String channelName,
    int totalParticipants,
  ) {
    final isFull = ref.watch(voiceLoungeFullscreenProvider);
    return _buildLoungeScaffold(context, [
      Positioned.fill(child: _buildBackground(context)),
      Column(
        children: [
          SizedBox(height: isFull ? 0 : 64),
          Expanded(child: contentArea),
        ],
      ),
      ..._buildSubmenuFollowers(conversationId),
      Positioned(bottom: 16, left: 0, right: 0, child: dock),
      if (!isFull)
        Positioned(
          top: 16,
          left: 60,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeaderBadge(context, channelName, totalParticipants),
              const SizedBox(width: 8),
              const CallMetricsChip(),
            ],
          ),
        ),
      if (isFull) const Positioned(top: 16, left: 60, child: CallMetricsChip()),
      Positioned(
        top: 16,
        right: 16,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFullscreenButton(context),
            const SizedBox(width: 8),
            if (_viewportTransformed && !_spotlightMode) ...[
              _buildResetViewButton(context),
              const SizedBox(width: 8),
            ],
            if (!_spotlightMode) ...[
              _buildClearBoardButton(context),
              const SizedBox(width: 8),
            ],
            _buildBackgroundPickerButton(context),
          ],
        ),
      ),
    ]);
  }

  /// Portrait layout: full [LoungeHeader] + content + floating dock.
  Widget _buildPortraitLayout(
    BuildContext context,
    Widget contentArea,
    Widget dock,
    String conversationId,
    String channelName,
    int totalParticipants,
  ) {
    final isFull = ref.watch(voiceLoungeFullscreenProvider);
    return _buildLoungeScaffold(context, [
      Positioned.fill(child: _buildBackground(context)),
      Column(
        children: [
          if (!isFull)
            LoungeHeader(
              channelName: channelName,
              participantCount: totalParticipants,
              onBackToChat: widget.onBackToChat,
              membersSidebarCollapsed: !widget.membersPanelVisible,
              onToggleMembers: widget.onToggleMembersPanel,
              trailing: const CallMetricsChip(),
            ),
          Expanded(child: contentArea),
          const SizedBox(height: 80),
        ],
      ),
      ..._buildSubmenuFollowers(conversationId),
      Positioned(bottom: 16, left: 0, right: 0, child: dock),
      Positioned(
        // When fullscreen-immersive, clear the iOS notch / Android
        // status bar with viewPadding.top so the corner controls
        // (including Fullscreen Exit) aren't hidden under the camera
        // cutout. When not fullscreen, sit below LoungeHeader.
        top: isFull ? (MediaQuery.viewPaddingOf(context).top + 8) : 60,
        right: 12,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFullscreenButton(context),
            const SizedBox(width: 8),
            if (_viewportTransformed && !_spotlightMode) ...[
              _buildResetViewButton(context),
              const SizedBox(width: 8),
            ],
            if (!_spotlightMode) ...[
              _buildClearBoardButton(context),
              const SizedBox(width: 8),
            ],
            _buildBackgroundPickerButton(context),
          ],
        ),
      ),
    ]);
  }

  /// Build all dock submenu follower widgets for the current [_activeSubmenu].
  List<Widget> _buildSubmenuFollowers(String conversationId) {
    if (_activeSubmenu == null) return const [];

    late final LayerLink link;
    late final Widget content;

    switch (_activeSubmenu!) {
      case DockSubmenu.mic:
        link = _micLayerLink;
        content = MicSubmenuStandalone(onRequestClose: _closeSubmenu);
      case DockSubmenu.camera:
        link = _cameraLayerLink;
        content = CameraSubmenuStandalone(onRequestClose: _closeSubmenu);
      case DockSubmenu.screenShare:
        link = _screenShareLayerLink;
        content = ScreenShareSubmenuStandalone(onRequestClose: _closeSubmenu);
      case DockSubmenu.draw:
        link = _drawingToolsLayerLink;
        content = DrawingToolsMenu(
          onToggleDrawing: _toggleDrawingMode,
          isDrawing: _isDrawing,
          conversationId: conversationId,
          onRequestClose: _closeSubmenu,
        );
    }

    return [
      CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -10),
        child: Material(
          color: Colors.transparent,
          child: DrawingToolsPanel(child: content),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final voiceLk = ref.watch(livekitVoiceProvider);
    final voiceSettings = ref.watch(voiceSettingsProvider);
    final screenShare = ref.watch(screenShareProvider);
    final channelsState = ref.watch(channelsProvider);
    final inPip = ref.watch(pipModeProvider).inPip;

    // Auto-enable drawing mode when the user picks a tool from the drawing
    // menu (Pen / Shape / Text / Eraser). Previously the menu only set the
    // tool, leaving `_isDrawing=false`, so the InteractiveViewer kept
    // claiming single-finger drags as pans — particularly visible on
    // mobile where users reported shapes "not drawing" (2026-05-27).
    final selectedTool = ref.watch(
      canvasProvider.select((c) => c.selectedTool),
    );
    if (selectedTool != CanvasTool.none && !_isDrawing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isDrawing) {
          setState(() => _isDrawing = true);
        }
      });
    }

    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId ?? '';

    // PiP: bare remote screen-share track only; falls through if PiP without a remote track.
    if (inPip) {
      final pipBody = _buildPipBody(ref);
      if (pipBody != null) return pipBody;
    }

    final channels = channelsState.channelsFor(conversationId);
    final activeChannel = channels.where((c) => c.id == channelId).firstOrNull;
    final channelName = activeChannel?.name ?? 'Voice';

    final memberAvatars = _buildMemberAvatars(conversationId);
    final room = ref.read(livekitVoiceProvider.notifier).room;
    final totalParticipants = 1 + (room?.remoteParticipants.length ?? 0);

    final contentArea = _buildContentArea(
      room: room,
      voiceLk: voiceLk,
      screenShare: screenShare,
      memberAvatars: memberAvatars,
    );

    final dock = FloatingDock(
      voiceState: voiceLk,
      voiceSettings: voiceSettings,
      screenShare: screenShare,
      conversationId: conversationId,
      channelId: channelId,
      isDrawing: _isDrawing,
      onToggleDrawing: _toggleDrawingMode,
      activeSubmenu: _activeSubmenu,
      onToggleSubmenu: (submenu) {
        setState(() {
          _activeSubmenu = _activeSubmenu == submenu ? null : submenu;
        });
      },
      micLayerLink: _micLayerLink,
      cameraLayerLink: _cameraLayerLink,
      screenShareLayerLink: _screenShareLayerLink,
      drawingToolsLayerLink: _drawingToolsLayerLink,
      spotlightMode: _spotlightMode,
      onToggleSpotlight: () {
        final notifier = ref.read(voiceLoungeViewModeProvider.notifier);
        final next = _spotlightMode
            ? VoiceLoungeView.canvas
            : VoiceLoungeView.spotlight;
        notifier.state = next;
        if (next == VoiceLoungeView.spotlight) {
          setState(() {
            _isDrawing = false;
            _activeSubmenu = null;
          });
        }
      },
    );

    // Wrap the canvas content in a fixed-size SizedBox so the
    // InteractiveViewer treats the child as a finite scrollable surface.
    // Every participant shares the same 4096×4096 logical canvas, which
    // makes circles drawn on a phone read as circles on desktop — only
    // the viewport (zoom + pan) differs between devices. See
    // `apps/client/lib/src/models/canvas_models.dart` for the
    // kCanvasWidth/kCanvasHeight constants and migration heuristic.
    // LoungeDrawingCanvas is the single owner of drawing-tool pointer
    // input (pen/highlight/shapes/eraser). Text tool is excluded — it's
    // a single tap handled by _DrawingLayer inside voice_canvas.dart so
    // the prompt closure can live where the State is. Including the
    // text tool here would double-dispatch the down event (Audit
    // Finding 1, 2026-05-28).
    final isDrawingOverlayActive =
        _isDrawing && selectedTool != CanvasTool.text;
    final mergedContent = SizedBox(
      width: kCanvasWidth,
      height: kCanvasHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          contentArea,
          if (!_spotlightMode)
            Positioned.fill(
              child: LoungeDrawingCanvas(isActive: isDrawingOverlayActive),
            ),
        ],
      ),
    );

    // Figma-style zoom + pan over a finite 4096×4096 surface.
    //
    // minScale uses the InteractiveViewer's ACTUAL region (via
    // LayoutBuilder below), not the full screen — the previous
    // MediaQuery-based calc included the header band + dock so the canvas
    // rendered smaller than the available area and only the top-left
    // corner was touchable (user feedback, 2026-05-27).
    //
    // Pan is disabled while drawing so single-pointer drags become
    // strokes. **Scale stays enabled**: pinch needs two fingers and
    // doesn't conflict with single-finger drawing — the drawing layer's
    // PanGestureRecognizer cancels when a second pointer arrives,
    // handing the pinch off to InteractiveViewer's ScaleGestureRecognizer.
    //
    // Background sits in a separate scaffold layer behind this widget
    // so it never moves with the canvas.
    const maxScale = 4.0;
    // Floor on how far the user can keep pinching out. Below this scale
    // the 100k canvas would render under one logical pixel and the math
    // collapses; in practice a user pinches to fit-content + a couple
    // more outs and stops. Picked an order of magnitude past
    // viewport/canvas so the Figma "zoom out forever" feel survives
    // without giving Flutter a degenerate transform to deal with.
    const minScaleFloor = 0.0001;

    final viewportContent = _spotlightMode
        ? mergedContent
        : LayoutBuilder(
            builder: (ctx, constraints) {
              final viewportW = constraints.maxWidth;
              final viewportH = constraints.maxHeight;
              final viewportSize = Size(viewportW, viewportH);
              // Cache the actual InteractiveViewer region so the
              // listener-driven helpers (_onViewportChanged,
              // _resetViewport, _toggleDoubleTapZoom) compute the same
              // pose on tablets / desktops as the initial-mount path.
              // MediaQuery.sizeOf includes the header + dock + members
              // panel and would mis-anchor the reset / double-tap.
              if (_interactiveViewportSize != viewportSize) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _interactiveViewportSize = viewportSize;
                });
              }
              // Initial pose: auto-fit to the bbox of existing strokes +
              // images so a late joiner doesn't have to hunt for the
              // content. Falls back to identity-at-origin when the
              // canvas is empty.
              if (!_viewportInitialised && viewportW > 0 && viewportH > 0) {
                _viewportInitialised = true;
                final canvas = ref.read(canvasProvider);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _viewport.value = _computeInitialPose(canvas, viewportSize);
                });
              }

              // Double-tap-to-zoom is gated on `!_isDrawing`. With a
              // drawing tool active, mouse double-clicks (and fast
              // drag-then-tap sequences) used to zoom the canvas
              // mid-stroke because the drawing layer's pan recogniser
              // only claims after kPanSlop (~18 px) — so a snappy
              // double-click never reached the drawing layer and fell
              // through to InteractiveViewer's double-tap (user
              // feedback 2026-05-28). Returning null keeps the tap
              // unrecognised by this layer so it dies in the gesture
              // arena rather than firing a zoom.
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTapDown: _isDrawing
                    ? null
                    : (details) => _toggleDoubleTapZoom(details.localPosition),
                child: InteractiveViewer(
                  transformationController: _viewport,
                  minScale: minScaleFloor,
                  maxScale: maxScale,
                  panEnabled: !_isDrawing,
                  scaleEnabled: true,
                  trackpadScrollCausesScale: true,
                  boundaryMargin: EdgeInsets.zero,
                  child: mergedContent,
                ),
              );
            },
          );

    return OrientationBuilder(
      builder: (context, orientation) {
        if (orientation == Orientation.landscape) {
          return _buildLandscapeLayout(
            context,
            viewportContent,
            dock,
            conversationId,
            channelName,
            totalParticipants,
          );
        }
        return _buildPortraitLayout(
          context,
          viewportContent,
          dock,
          conversationId,
          channelName,
          totalParticipants,
        );
      },
    );
  }
}

/// Sliders + colour disk for the built-in vertex-mesh background.
/// Lives in this file because the parent dialog is owned here; lifting it
/// to its own file would force exporting private theme accessors.
class _VertexTunableControls extends ConsumerWidget {
  const _VertexTunableControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bg = ref.watch(voiceLoungeBackgroundProvider);
    final notifier = ref.read(voiceLoungeBackgroundProvider.notifier);
    final dotColor = bg.vertexColor ?? context.accent;
    final isCustomColor = bg.vertexColor != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mesh',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              'Dot colour',
              style: TextStyle(color: context.textPrimary, fontSize: 13),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () async {
                Color picked = dotColor;
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: ctx.surface,
                    content: SingleChildScrollView(
                      child: ColorPicker(
                        pickerColor: dotColor,
                        onColorChanged: (c) => picked = c,
                        enableAlpha: false,
                        labelTypes: const [],
                        pickerAreaHeightPercent: 0.6,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Use colour'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await notifier.setVertexColor(picked);
                }
              },
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isCustomColor ? context.accent : context.border,
                    width: isCustomColor ? 2 : 1,
                  ),
                ),
              ),
            ),
            if (isCustomColor)
              IconButton(
                tooltip: 'Reset dot colour',
                icon: Icon(
                  Icons.refresh,
                  size: 16,
                  color: context.textSecondary,
                ),
                onPressed: () => notifier.setVertexColor(null),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                'Density',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
            ),
            Expanded(
              flex: 5,
              child: Slider(
                value: bg.vertexCount.toDouble(),
                min: 10,
                max: 120,
                divisions: 22,
                label: '${bg.vertexCount}',
                onChanged: (v) => notifier.setVertexCount(v.round()),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                'Reach',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
            ),
            Expanded(
              flex: 5,
              child: Slider(
                value: bg.connectionDistance,
                min: 40,
                max: 240,
                divisions: 20,
                label: '${bg.connectionDistance.round()}',
                onChanged: notifier.setConnectionDistance,
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: Icon(Icons.restore, size: 16, color: context.textSecondary),
            label: Text(
              'Reset mesh',
              style: TextStyle(color: context.textSecondary, fontSize: 12),
            ),
            onPressed: notifier.resetVertexDefaults,
          ),
        ),
      ],
    );
  }
}
