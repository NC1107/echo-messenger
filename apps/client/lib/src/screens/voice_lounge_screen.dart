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
    show CanvasTool, kCanvasHeight, kCanvasWidth;
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

  /// True once the viewport has been initialised to the "canvas top-left at
  /// viewport top-left, fully zoomed out" pose. Reset to false when this
  /// widget is rebuilt for a different conversation/channel so each lounge
  /// session starts from a clean canvas overview.
  bool _viewportInitialised = false;

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
    // The reset-view button only needs to appear when the user has actively
    // panned or zoomed away from the initial fit-to-screen pose. The fit
    // pose itself isn't identity (it's a uniform scale), so use the matrix
    // translation + a tolerance check on scale instead.
    final m = _viewport.value;
    final size = MediaQuery.maybeSizeOf(context) ?? Size.zero;
    final fit = size.width <= 0 || size.height <= 0
        ? 1.0
        : math.min(size.width / kCanvasWidth, size.height / kCanvasHeight);
    final scaleDiff = (m.getMaxScaleOnAxis() - fit).abs();
    final translated = m.getTranslation().length > 0.5;
    final transformed = scaleDiff > 1e-3 || translated;
    if (transformed != _viewportTransformed) {
      setState(() => _viewportTransformed = transformed);
    }
  }

  void _resetViewport() {
    // Reset to the same starting pose used on first mount: canvas top-left
    // at viewport top-left, scaled so the entire 4096-px surface fits.
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) {
      _viewport.value = Matrix4.identity();
      return;
    }
    final fit = math.min(
      size.width / kCanvasWidth,
      size.height / kCanvasHeight,
    );
    _viewport.value = Matrix4.identity()..scaleByDouble(fit, fit, fit, 1);
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
          onToggleDrawing: () => setState(() => _isDrawing = !_isDrawing),
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
      onToggleDrawing: () => setState(() => _isDrawing = !_isDrawing),
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
    final mergedContent = SizedBox(
      width: kCanvasWidth,
      height: kCanvasHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          contentArea,
          if (!_spotlightMode)
            Positioned.fill(child: LoungeDrawingCanvas(isActive: _isDrawing)),
        ],
      ),
    );

    // Figma-style zoom + pan over a finite 4096×4096 surface.
    //
    // minScale is computed dynamically so at full zoom-out the entire
    // canvas fits inside the viewport (no wasted space outside, no
    // letterboxing inside). On a small phone this might be ~0.1; on a
    // 4K monitor it can exceed 1.0 — that's fine, the user can still
    // zoom in up to maxScale for fine detail. Pan is disabled while
    // drawing so single-pointer drags become strokes; pinch + trackpad
    // scroll still zoom regardless.
    //
    // Background sits in a separate scaffold layer behind this widget
    // so it never moves with the canvas.
    final size = MediaQuery.sizeOf(context);
    final viewportW = size.width;
    final viewportH = size.height;
    final minScale = viewportW <= 0 || viewportH <= 0
        ? 0.1
        : math.min(viewportW / kCanvasWidth, viewportH / kCanvasHeight);
    const maxScale = 4.0;

    // Apply the initial pose once we have a non-zero viewport: place the
    // canvas top-left at the viewport top-left, scaled so the whole
    // canvas fits. The user can then pan/zoom from a known starting
    // overview instead of landing somewhere arbitrary inside a 4096-px
    // surface.
    if (!_viewportInitialised && viewportW > 0 && viewportH > 0) {
      _viewportInitialised = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _viewport.value = Matrix4.identity()
          ..scaleByDouble(minScale, minScale, minScale, 1);
      });
    }

    final viewportContent = _spotlightMode
        ? mergedContent
        : InteractiveViewer(
            transformationController: _viewport,
            minScale: minScale,
            maxScale: maxScale,
            // Both pan AND scale must be off while a tool is in hand —
            // otherwise InteractiveViewer's ScaleGestureRecognizer can claim
            // single-pointer drags via its scale-of-one path and turn a
            // shape draw into a viewport pan (image #57, 2026-05-27). The
            // drawing layer's HitTestBehavior.opaque pairs with this to
            // guarantee the gesture arena is uncontested.
            panEnabled: !_isDrawing,
            scaleEnabled: !_isDrawing,
            trackpadScrollCausesScale: true,
            boundaryMargin: EdgeInsets.zero,
            child: mergedContent,
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
