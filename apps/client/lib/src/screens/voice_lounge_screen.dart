import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_settings_provider.dart';
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
  bool _spotlightMode = false;

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

  void _closeSubmenu() => setState(() => _activeSubmenu = null);

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

    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId ?? '';

    final channels = channelsState.channelsFor(conversationId);
    final activeChannel = channels.where((c) => c.id == channelId).firstOrNull;
    final channelName = activeChannel?.name ?? 'Voice';

    // Build a username -> avatarUrl map from conversation members so remote
    // participant tiles can display profile pictures.
    final serverUrl = ref.read(serverUrlProvider);
    final conversations = ref.watch(conversationsProvider).conversations;
    final conversation = conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final memberAvatars = <String, String?>{};
    if (conversation != null) {
      for (final m in conversation.members) {
        final resolved = m.avatarUrl != null && m.avatarUrl!.isNotEmpty
            ? (m.avatarUrl!.startsWith('http')
                  ? m.avatarUrl
                  : '$serverUrl${m.avatarUrl}')
            : null;
        memberAvatars[m.username] = resolved;
      }
    }

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
          return Listener(
            onPointerDown: (e) {
              if (e.buttons == kSecondaryButton && _isDrawing) {
                setState(() => _isDrawing = false);
              }
            },
            child: Container(
              color: context.mainBg,
              child: ClipRect(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: VertexMeshBackground(
                        accentColor: context.accent,
                        backgroundColor: context.mainBg,
                      ),
                    ),
                    Column(children: [Expanded(child: contentArea)]),
                    if (!_spotlightMode) Positioned.fill(child: drawingOverlay),
                    ..._buildSubmenuFollowers(conversationId),
                    Positioned(bottom: 16, left: 0, right: 0, child: dock),
                    Positioned(
                      top: 16,
                      left: 60,
                      child: _buildHeaderBadge(
                        context,
                        channelName,
                        totalParticipants,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // Portrait: full header bar + content + floating dock
        return Listener(
          onPointerDown: (e) {
            if (e.buttons == kSecondaryButton && _isDrawing) {
              setState(() => _isDrawing = false);
            }
          },
          child: Container(
            color: context.mainBg,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: VertexMeshBackground(
                      accentColor: context.accent,
                      backgroundColor: context.mainBg,
                    ),
                  ),
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
