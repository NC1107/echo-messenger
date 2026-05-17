import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_lounge_background_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../services/debug_log_service.dart';
import '../services/pip_controller.dart';
import '../theme/echo_theme.dart';
import '../utils/canvas_utils.dart';
import '../widgets/lounge_drawing_canvas.dart';
import '../widgets/vertex_mesh_background.dart';
import '../widgets/voice_canvas.dart';
import 'voice_lounge/dock_submenus.dart';
import 'voice_lounge/drawing_tools_menu.dart';
import 'voice_lounge/floating_dock.dart';
import 'voice_lounge/lounge_constants.dart';
import 'voice_lounge/lounge_header.dart';
import 'voice_lounge/participant_grid.dart';
import 'voice_lounge/screen_share.dart';

/// Discord-style voice lounge that replaces the chat content area when the
/// user is in a voice call and chooses to view the lounge.
class VoiceLoungeScreen extends ConsumerStatefulWidget {
  /// Called when the user taps "Back to chat".
  final VoidCallback? onBackToChat;

  const VoiceLoungeScreen({super.key, this.onBackToChat});

  @override
  ConsumerState<VoiceLoungeScreen> createState() => _VoiceLoungeScreenState();
}

class _VoiceLoungeScreenState extends ConsumerState<VoiceLoungeScreen> {
  /// Key of the tile currently in focus. Null = grid / auto-spotlight view.
  /// Format: 'local', 'remote-{sid}', 'screenshare-local', 'screenshare-{sid}'.
  String? _focusedTileKey;

  /// Whether the drawing canvas overlay is active.
  bool _isDrawing = false;

  /// Anchors for dock submenu panels.
  final LayerLink _drawingToolsLayerLink = LayerLink();
  final LayerLink _micLayerLink = LayerLink();
  final LayerLink _cameraLayerLink = LayerLink();
  final LayerLink _screenShareLayerLink = LayerLink();

  /// Which dock submenu is currently open (null = none).
  DockSubmenu? _activeSubmenu;

  /// When true, force the spotlight/participant grid instead of the canvas.
  /// Defaults to true so users land in the familiar grid view; the canvas
  /// (vertex mesh + draggable pucks) is opt-in via the dock toggle.
  bool _spotlightMode = true;

  @override
  void initState() {
    super.initState();
    // Breadcrumb: VoiceLoungeScreen mounted. This fires immediately after
    // joinChannel succeeds and the route transitions to the lounge. If the
    // app crashes before this appears in logs, the crash is in joinChannel
    // itself (captured by channel_bar.dart breadcrumbs). If it appears but
    // no further breadcrumbs follow, the crash is inside the lounge build.
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
    DebugLogService.instance.log(
      LogLevel.info,
      'VoiceLoungeUI',
      'VoiceLoungeScreen disposed',
    );
    super.dispose();
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
              child: GestureDetector(
                onDoubleTap: () =>
                    setState(() => _focusedTileKey = 'screenshare-$sid'),
                child: lk.VideoTrackRenderer(
                  track,
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
    return Container(
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
          if (widget.onBackToChat != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: widget.onBackToChat,
              child: const Icon(
                Icons.chat_outlined,
                size: 16,
                color: Colors.white70,
              ),
            ),
          ],
        ],
      ),
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
              child: GestureDetector(
                onDoubleTap: () =>
                    setState(() => _focusedTileKey = kScreenshareLocal),
                child: LocalScreenShareTrack(ref: ref),
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
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final srcPath = picked.path;
      if (srcPath == null || srcPath.isEmpty) return;

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
          // file is in a stable location.
        }
      }

      await ref
          .read(voiceLoungeBackgroundProvider.notifier)
          .setCustomBackgroundPath(resolved);
    } catch (e) {
      debugPrint('[VoiceLoungeScreen] pick background failed: $e');
    }
  }

  Future<void> _clearBackground() async {
    await ref.read(voiceLoungeBackgroundProvider.notifier).clear();
  }

  /// Show a tiny bottom-sheet with "Choose image" + "Reset to default" so the
  /// single icon button covers both operations.
  Future<void> _openBackgroundMenu(BuildContext ctx) async {
    final hasCustom =
        ref.read(voiceLoungeBackgroundProvider).customBackgroundPath != null;
    await showModalBottomSheet<void>(
      context: ctx,
      builder: (sheetCtx) {
        return SafeArea(
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
                  title: const Text('Reset to default'),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _clearBackground();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// Resolves the active background widget for the lounge.  When the user
  /// has picked a custom image AND the file still exists on disk, renders
  /// it as a [BoxFit.cover] backdrop with a 50% black overlay for legibility.
  /// Otherwise falls back to the original [VertexMeshBackground].
  Widget _buildBackground(BuildContext context) {
    final bg = ref.watch(voiceLoungeBackgroundProvider);
    final path = bg.customBackgroundPath;
    if (customBackgroundFileExists(path)) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(path!),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => VertexMeshBackground(
              accentColor: context.accent,
              backgroundColor: context.mainBg,
            ),
          ),
          const ColoredBox(color: Color(0x80000000)),
        ],
      );
    }
    return VertexMeshBackground(
      accentColor: context.accent,
      backgroundColor: context.mainBg,
    );
  }

  /// Small circular icon button that opens the background-picker menu.  This
  /// is the ONE settings entry-point for the customizable voice-lounge
  /// background feature.
  Widget _buildBackgroundPickerButton(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Voice lounge background settings',
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _openBackgroundMenu(context),
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.wallpaper, size: 18, color: Colors.white),
          ),
        ),
      ),
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
    Widget drawingOverlay,
    String conversationId,
    String channelName,
    int totalParticipants,
  ) {
    return _buildLoungeScaffold(context, [
      Positioned.fill(child: _buildBackground(context)),
      Column(children: [Expanded(child: contentArea)]),
      if (!_spotlightMode) Positioned.fill(child: drawingOverlay),
      ..._buildSubmenuFollowers(conversationId),
      Positioned(bottom: 16, left: 0, right: 0, child: dock),
      Positioned(
        top: 16,
        left: 60,
        child: _buildHeaderBadge(context, channelName, totalParticipants),
      ),
      Positioned(
        top: 16,
        right: 16,
        child: _buildBackgroundPickerButton(context),
      ),
    ]);
  }

  /// Portrait layout: full [LoungeHeader] + content + floating dock.
  Widget _buildPortraitLayout(
    BuildContext context,
    Widget contentArea,
    Widget dock,
    Widget drawingOverlay,
    String conversationId,
    String channelName,
    int totalParticipants,
  ) {
    return _buildLoungeScaffold(context, [
      Positioned.fill(child: _buildBackground(context)),
      Column(
        children: [
          LoungeHeader(
            channelName: channelName,
            participantCount: totalParticipants,
            onBackToChat: widget.onBackToChat,
          ),
          Expanded(child: contentArea),
          // Space for the floating dock
          const SizedBox(height: 80),
        ],
      ),
      if (!_spotlightMode) Positioned.fill(child: drawingOverlay),
      ..._buildSubmenuFollowers(conversationId),
      Positioned(bottom: 16, left: 0, right: 0, child: dock),
      Positioned(
        top: 12,
        right: 12,
        child: _buildBackgroundPickerButton(context),
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

    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId ?? '';

    // Picture-in-Picture: render only the remote screen-share track in a
    // bare full-bleed VideoTrackRenderer.  No header, no dock, no canvas
    // chrome — the whole point of PiP is a tiny system window with just
    // the relevant pixels.  Falls through to the regular layout if the
    // OS reports PiP without a remote track (e.g. transient state).
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
        setState(() {
          _spotlightMode = !_spotlightMode;
          if (_spotlightMode) {
            _isDrawing = false;
            _activeSubmenu = null;
          }
        });
      },
    );

    final drawingOverlay = LoungeDrawingCanvas(isActive: _isDrawing);

    return OrientationBuilder(
      builder: (context, orientation) {
        // In landscape: drop the 56-px header bar to maximise stream height,
        // replacing it with a small floating badge in the top-left corner.
        if (orientation == Orientation.landscape) {
          return _buildLandscapeLayout(
            context,
            contentArea,
            dock,
            drawingOverlay,
            conversationId,
            channelName,
            totalParticipants,
          );
        }
        // Portrait: full header bar + content + floating dock
        return _buildPortraitLayout(
          context,
          contentArea,
          dock,
          drawingOverlay,
          conversationId,
          channelName,
          totalParticipants,
        );
      },
    );
  }
}
