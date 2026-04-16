import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../models/canvas_models.dart';
import '../providers/auth_provider.dart';
import '../providers/canvas_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/canvas_utils.dart';
import '../widgets/lounge_drawing_canvas.dart' hide CanvasImage;
import '../widgets/vertex_mesh_background.dart';
import '../widgets/voice_canvas.dart';

const _kScreenshareLocal = 'screenshare-local';

/// Which dock submenu is currently open.
enum _DockSubmenu { mic, camera, screenShare, draw }

/// Discord-style voice lounge that replaces the chat content area when the
/// user is in a voice call and chooses to view the lounge.
class VoiceLoungeScreen extends ConsumerStatefulWidget {
  /// Called when the user taps "Back to chat".
  final VoidCallback? onBackToChat;

  const VoiceLoungeScreen({super.key, this.onBackToChat});

  /// Screen sharing is supported on desktop, web, and Android.
  /// iOS requires a Broadcast Upload Extension which is not yet implemented.
  static bool get _supportsScreenShare {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  ConsumerState<VoiceLoungeScreen> createState() => _VoiceLoungeScreenState();
}

class _VoiceLoungeScreenState extends ConsumerState<VoiceLoungeScreen> {
  /// Key of the tile currently in focus. Null = grid / auto-spotlight view.
  /// Format: 'local', 'remote-{sid}', 'screenshare-local', 'screenshare-{sid}'.
  String? _focusedTileKey;

  /// Whether the drawing canvas overlay is active.
  bool _isDrawing = false;

  /// Global key for the drawing canvas to access its state.
  final _drawingCanvasKey = GlobalKey<LoungeDrawingCanvasState>();

  /// Anchors for dock submenu panels.
  final LayerLink _drawingToolsLayerLink = LayerLink();
  final LayerLink _micLayerLink = LayerLink();
  final LayerLink _cameraLayerLink = LayerLink();
  final LayerLink _screenShareLayerLink = LayerLink();

  /// Which dock submenu is currently open (null = none).
  _DockSubmenu? _activeSubmenu;

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
    if (tileKey == _kScreenshareLocal) {
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
        builder: (_) => _FullscreenVideoPage(track: track, mirror: mirror),
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
            _DraggableScreenShareWindow(
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
                  fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
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
                    setState(() => _focusedTileKey = _kScreenshareLocal),
                child: _ScreenShareViewer(ref: ref),
              ),
              const SizedBox(height: 16),
            ],
            _ParticipantGrid(
              room: room,
              voiceState: voiceLk,
              localAvatarUrl: _buildAvatarUrl(),
              memberAvatars: memberAvatars,
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
            _DraggableScreenShareWindow(
              key: const ValueKey('local-share'),
              initialRight: 16,
              initialTop: 16,
              label: 'Your screen',
              isLocal: true,
              child: GestureDetector(
                onDoubleTap: () =>
                    setState(() => _focusedTileKey = _kScreenshareLocal),
                child: _ScreenShareViewer(ref: ref),
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
              onTap: () => setState(() => _focusedTileKey = _kScreenshareLocal),
              child: _ScreenShareViewer(ref: ref),
            ),
          if (screenShare.isScreenSharing) const SizedBox(height: 16),
          _ParticipantGrid(
            room: room,
            voiceState: voiceLk,
            localAvatarUrl: _buildAvatarUrl(),
            memberAvatars: memberAvatars,
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
                  fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
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
          child: _ParticipantGrid(
            room: room,
            voiceState: voiceLk,
            localAvatarUrl: _buildAvatarUrl(),
            memberAvatars: memberAvatars,
            compact: true,
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
      case _DockSubmenu.mic:
        link = _micLayerLink;
        content = _MicSubmenuStandalone(onRequestClose: _closeSubmenu);
      case _DockSubmenu.camera:
        link = _cameraLayerLink;
        content = _CameraSubmenuStandalone(onRequestClose: _closeSubmenu);
      case _DockSubmenu.screenShare:
        link = _screenShareLayerLink;
        content = _ScreenShareSubmenuStandalone(onRequestClose: _closeSubmenu);
      case _DockSubmenu.draw:
        link = _drawingToolsLayerLink;
        content = _DrawingToolsMenu(
          drawingCanvasKey: _drawingCanvasKey,
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
          child: _DrawingToolsPanel(child: content),
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

    final dock = _FloatingDock(
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

    final drawingOverlay = LoungeDrawingCanvas(
      key: _drawingCanvasKey,
      isActive: _isDrawing,
    );

    return OrientationBuilder(
      builder: (context, orientation) {
        // In landscape: drop the 56-px header bar to maximise stream height,
        // replacing it with a small floating badge in the top-left corner.
        if (orientation == Orientation.landscape) {
          return Container(
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
          );
        }

        // Portrait: full header bar + content + floating dock
        return Container(
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
                    _LoungeHeader(
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
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _LoungeHeader extends StatelessWidget {
  final String channelName;
  final int participantCount;
  final VoidCallback? onBackToChat;

  const _LoungeHeader({
    required this.channelName,
    required this.participantCount,
    this.onBackToChat,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq, size: 20, color: EchoTheme.online),
          const SizedBox(width: 10),
          Text(
            channelName,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: context.surfaceHover,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$participantCount participant${participantCount != 1 ? 's' : ''}',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Spacer(),
          if (onBackToChat != null)
            TextButton.icon(
              onPressed: onBackToChat,
              icon: const Icon(Icons.chat_outlined, size: 16),
              label: const Text('Back to chat'),
              style: TextButton.styleFrom(
                foregroundColor: context.textSecondary,
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Participant grid
// ---------------------------------------------------------------------------

class _ParticipantGrid extends StatelessWidget {
  final lk.Room? room;
  final LiveKitVoiceState voiceState;
  final String? localAvatarUrl;
  final Map<String, String?> memberAvatars;
  final bool compact;

  /// Called with the tile key when the user taps a tile to focus it.
  final void Function(String key)? onTileTap;

  const _ParticipantGrid({
    required this.room,
    required this.voiceState,
    this.localAvatarUrl,
    this.memberAvatars = const {},
    this.compact = false,
    this.onTileTap,
  });

  @override
  Widget build(BuildContext context) {
    if (room == null) {
      return _buildPlaceholder(context, 'Connecting to voice...');
    }

    final tiles = <Widget>[
      if (room!.localParticipant != null)
        _buildLocalTile(room!.localParticipant!),
      ...room!.remoteParticipants.values.map(_buildRemoteTile),
    ];

    if (tiles.isEmpty) {
      return _buildPlaceholder(context, 'No participants');
    }

    if (compact) {
      return _buildCompactLayout(tiles);
    }
    return _buildGridLayout(tiles);
  }

  Widget _buildPlaceholder(BuildContext context, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          message,
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildLocalTile(lk.LocalParticipant localParticipant) {
    final localVideo = localParticipant.videoTrackPublications
        .where(
          (pub) => pub.track != null && pub.source == lk.TrackSource.camera,
        )
        .firstOrNull;

    final localHasVideo =
        localVideo?.track != null && voiceState.isVideoEnabled;

    return _ParticipantTile(
      key: const ValueKey('local'),
      name: 'You',
      avatarUrl: localAvatarUrl,
      hasVideo: localHasVideo,
      videoTrack: localHasVideo ? localVideo?.track as lk.VideoTrack? : null,
      mirror: true,
      audioLevel: voiceState.localAudioLevel,
      isMuted: !voiceState.isCaptureEnabled,
      isLocal: true,
      onTap: onTileTap != null ? () => onTileTap!('local') : null,
    );
  }

  Widget _buildRemoteTile(lk.RemoteParticipant participant) {
    final displayName = participantDisplayName(participant);
    final videoTrack = participant.videoTrackPublications
        .where(
          (pub) =>
              pub.track != null &&
              pub.track is lk.VideoTrack &&
              pub.source == lk.TrackSource.camera,
        )
        .firstOrNull;

    final identity = participant.identity.isNotEmpty
        ? participant.identity
        : participant.sid.toString();
    final audioLevel = voiceState.peerAudioLevels[identity] ?? 0.0;

    return _ParticipantTile(
      key: ValueKey('remote-${participant.sid}'),
      name: displayName.length > 16
          ? displayName.substring(0, 16)
          : displayName,
      avatarUrl: memberAvatars[displayName],
      hasVideo: videoTrack?.track != null,
      videoTrack: videoTrack?.track as lk.VideoTrack?,
      mirror: false,
      audioLevel: audioLevel,
      isMuted: participant.isMuted,
      connectionState: voiceState.peerConnectionStates[identity],
      onTap: onTileTap != null
          ? () => onTileTap!('remote-${participant.sid}')
          : null,
      onMuteForMe: () async {
        for (final pub in participant.audioTrackPublications) {
          final track = pub.track;
          if (track != null) {
            if (pub.subscribed) {
              await track.disable();
            } else {
              await track.enable();
            }
          }
        }
      },
    );
  }

  Widget _buildCompactLayout(List<Widget> tiles) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: tiles.length,
      separatorBuilder: (context, index) => const SizedBox(width: 8),
      itemBuilder: (_, i) => SizedBox(width: 100, child: tiles[i]),
    );
  }

  Widget _buildGridLayout(List<Widget> tiles) {
    return Center(
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        alignment: WrapAlignment.center,
        children: tiles
            .map((t) => SizedBox(width: 96, height: 128, child: t))
            .toList(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Single participant tile
// ---------------------------------------------------------------------------

class _ParticipantTile extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final bool hasVideo;
  final lk.VideoTrack? videoTrack;
  final bool mirror;
  final double audioLevel;
  final bool isMuted;
  final String? connectionState;
  final bool isLocal;
  final VoidCallback? onTap;
  final VoidCallback? onMuteForMe;

  const _ParticipantTile({
    super.key,
    required this.name,
    this.avatarUrl,
    required this.hasVideo,
    this.videoTrack,
    this.mirror = false,
    this.audioLevel = 0.0,
    this.isMuted = false,
    this.connectionState,
    this.isLocal = false,
    this.onTap,
    this.onMuteForMe,
  });

  @override
  Widget build(BuildContext context) {
    final isSpeaking = audioLevel > 0.01;

    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: !isLocal && onMuteForMe != null
          ? (details) => _showParticipantMenu(context, details.globalPosition)
          : null,
      onLongPress: !isLocal && onMuteForMe != null ? onMuteForMe : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSpeaking ? EchoTheme.online : context.border,
            width: isSpeaking ? 2.0 : 1.0,
          ),
          boxShadow: isSpeaking
              ? [
                  BoxShadow(
                    color: EchoTheme.online.withValues(alpha: 0.3),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Container(
          color: context.surface.withValues(alpha: kIsWeb ? 0.65 : 0.45),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Video or avatar
              if (hasVideo && videoTrack != null)
                lk.VideoTrackRenderer(
                  videoTrack!,
                  fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirrorMode: mirror
                      ? lk.VideoViewMirrorMode.mirror
                      : lk.VideoViewMirrorMode.off,
                )
              else
                _AvatarCircle(
                  name: name,
                  avatarUrl: avatarUrl,
                  isSpeaking: isSpeaking,
                ),
              _buildNameLabel(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNameLabel(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isMuted)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.mic_off, size: 14, color: EchoTheme.danger),
              ),
            if (connectionState != null && connectionState != 'connected')
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.signal_cellular_alt,
                  size: 14,
                  color: connectionState == 'reconnecting'
                      ? EchoTheme.warning
                      : context.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showParticipantMenu(BuildContext context, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.border),
      ),
      items: [
        PopupMenuItem(
          value: 'mute',
          child: Row(
            children: [
              Icon(Icons.volume_off, size: 16, color: context.textSecondary),
              const SizedBox(width: 8),
              Text(
                'Toggle mute for me',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'mute') onMuteForMe?.call();
    });
  }
}

// ---------------------------------------------------------------------------
// Avatar circle (shown when no video)
// ---------------------------------------------------------------------------

class _AvatarCircle extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final bool isSpeaking;

  const _AvatarCircle({
    required this.name,
    this.avatarUrl,
    required this.isSpeaking,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    // Generate a stable color from the name
    final hue = (name.hashCode % 360).abs().toDouble();
    final avatarColor = HSLColor.fromAHSL(1.0, hue, 0.5, 0.35).toColor();

    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: avatarColor,
          border: Border.all(
            color: isSpeaking ? EchoTheme.online : Colors.transparent,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: avatarUrl != null
            ? Image.network(
                avatarUrl!,
                fit: BoxFit.cover,
                width: 48,
                height: 48,
                errorBuilder: (_, _, _) => Center(
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
            : Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen share viewer (local)
// ---------------------------------------------------------------------------

class _ScreenShareViewer extends StatelessWidget {
  final WidgetRef ref;

  const _ScreenShareViewer({required this.ref});

  @override
  Widget build(BuildContext context) {
    // Use the LiveKit room's local participant screen share track directly
    // instead of screenShareProvider.screenRenderer (which is null when
    // LiveKit SDK handles capture via setScreenShareEnabled).
    final room = ref.read(livekitVoiceProvider.notifier).room;
    final localParticipant = room?.localParticipant;
    if (localParticipant == null) return const SizedBox.shrink();

    final screenPub = localParticipant.videoTrackPublications
        .where(
          (pub) =>
              pub.track != null &&
              pub.source == lk.TrackSource.screenShareVideo,
        )
        .firstOrNull;

    final screenTrack = screenPub?.track as lk.VideoTrack?;
    if (screenTrack == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 400),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: lk.VideoTrackRenderer(
                screenTrack,
                fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: EchoTheme.danger.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.screen_share, size: 14, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    'Your screen',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 12,
            child: IconButton(
              icon: const Icon(Icons.close, size: 18, color: Colors.white),
              tooltip: 'Stop sharing',
              onPressed: () async {
                await ref
                    .read(livekitVoiceProvider.notifier)
                    .setScreenShareEnabled(false);
                ref
                    .read(screenShareProvider.notifier)
                    .setLiveKitScreenShareActive(false);
              },
              style: IconButton.styleFrom(
                backgroundColor: EchoTheme.danger.withValues(alpha: 0.7),
                padding: const EdgeInsets.all(6),
                minimumSize: const Size(28, 28),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Floating mac-style dock
// ---------------------------------------------------------------------------

class _FloatingDock extends ConsumerWidget {
  final LiveKitVoiceState voiceState;
  final VoiceSettingsState voiceSettings;
  final ScreenShareState screenShare;
  final String conversationId;
  final String channelId;
  final bool isDrawing;
  final VoidCallback onToggleDrawing;
  final _DockSubmenu? activeSubmenu;
  final ValueChanged<_DockSubmenu> onToggleSubmenu;
  final LayerLink micLayerLink;
  final LayerLink cameraLayerLink;
  final LayerLink screenShareLayerLink;
  final LayerLink drawingToolsLayerLink;
  final bool spotlightMode;
  final VoidCallback onToggleSpotlight;

  const _FloatingDock({
    required this.voiceState,
    required this.voiceSettings,
    required this.screenShare,
    required this.conversationId,
    required this.channelId,
    required this.isDrawing,
    required this.onToggleDrawing,
    required this.activeSubmenu,
    required this.onToggleSubmenu,
    required this.micLayerLink,
    required this.cameraLayerLink,
    required this.screenShareLayerLink,
    required this.drawingToolsLayerLink,
    required this.spotlightMode,
    required this.onToggleSpotlight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: context.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: context.border.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // -- Mic + submenu (noise suppression) --
            _DockButtonWithSubmenu(
              icon: voiceSettings.selfMuted ? Icons.mic_off : Icons.mic,
              tooltip: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
              isActive: voiceSettings.selfMuted,
              activeColor: EchoTheme.danger,
              onPressed: () async {
                final notifier = ref.read(voiceSettingsProvider.notifier);
                final nextMuted = !voiceSettings.selfMuted;
                await notifier.setSelfMuted(nextMuted);
                ref
                    .read(livekitVoiceProvider.notifier)
                    .setCaptureEnabled(
                      !nextMuted && !voiceSettings.selfDeafened,
                    );
              },
              onSubmenuTap: () => onToggleSubmenu(_DockSubmenu.mic),
              submenuActive: activeSubmenu == _DockSubmenu.mic,
              submenuLayerLink: micLayerLink,
            ),
            // -- Camera + submenu (device picker) --
            _DockButtonWithSubmenu(
              icon: voiceState.isVideoEnabled
                  ? Icons.videocam
                  : Icons.videocam_off,
              tooltip: voiceState.isVideoEnabled
                  ? 'Turn off camera'
                  : 'Turn on camera',
              isActive: voiceState.isVideoEnabled,
              activeColor: context.accent,
              onPressed: () async {
                await ref.read(livekitVoiceProvider.notifier).toggleVideo();
              },
              onSubmenuTap: () => onToggleSubmenu(_DockSubmenu.camera),
              submenuActive: activeSubmenu == _DockSubmenu.camera,
              submenuLayerLink: cameraLayerLink,
            ),
            // -- Screen Share + submenu (quality settings) --
            if (VoiceLoungeScreen._supportsScreenShare)
              _DockButtonWithSubmenu(
                icon: screenShare.isScreenSharing
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                tooltip: screenShare.isScreenSharing
                    ? 'Stop sharing'
                    : 'Share screen',
                isActive: screenShare.isScreenSharing,
                activeColor: EchoTheme.online,
                onPressed: () async {
                  final lkNotifier = ref.read(livekitVoiceProvider.notifier);
                  final ssNotifier = ref.read(screenShareProvider.notifier);
                  if (screenShare.isScreenSharing) {
                    await lkNotifier.setScreenShareEnabled(false);
                    ssNotifier.setLiveKitScreenShareActive(false);
                  } else {
                    if (lk.lkPlatformIsDesktop()) {
                      try {
                        final source = await showDialog<DesktopCapturerSource>(
                          context: context,
                          builder: (_) => lk.ScreenSelectDialog(),
                        );
                        if (source == null) return;
                        final track =
                            await lk.LocalVideoTrack.createScreenShareTrack(
                              lk.ScreenShareCaptureOptions(
                                sourceId: source.id,
                                maxFrameRate: 15.0,
                              ),
                            );
                        final room = lkNotifier.room;
                        if (room != null) {
                          await room.localParticipant?.publishVideoTrack(track);
                          ssNotifier.setLiveKitScreenShareActive(true);
                        }
                      } catch (e) {
                        debugPrint(
                          '[VoiceLounge] Desktop screen share failed: $e',
                        );
                      }
                    } else {
                      final ok = await lkNotifier.setScreenShareEnabled(true);
                      if (ok) {
                        ssNotifier.setLiveKitScreenShareActive(true);
                      }
                    }
                  }
                },
                onSubmenuTap: () => onToggleSubmenu(_DockSubmenu.screenShare),
                submenuActive: activeSubmenu == _DockSubmenu.screenShare,
                submenuLayerLink: screenShareLayerLink,
              ),
            // -- Draw toggle + submenu (tools) -- (hidden in spotlight mode)
            if (!spotlightMode)
              _DockButtonWithSubmenu(
                icon: Icons.edit,
                tooltip: isDrawing ? 'Stop drawing' : 'Draw',
                isActive: isDrawing,
                activeColor: context.accent,
                onPressed: onToggleDrawing,
                onSubmenuTap: () => onToggleSubmenu(_DockSubmenu.draw),
                submenuActive: activeSubmenu == _DockSubmenu.draw,
                submenuLayerLink: drawingToolsLayerLink,
              ),
            _dockDivider(context),
            // ── Deafen (tap only) ──
            _buildDockItem(
              context,
              icon: voiceSettings.selfDeafened
                  ? Icons.headset_off
                  : Icons.headset,
              tooltip: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
              isActive: voiceSettings.selfDeafened,
              activeColor: EchoTheme.danger,
              onPressed: () async {
                final notifier = ref.read(voiceSettingsProvider.notifier);
                final nextDeafened = !voiceSettings.selfDeafened;
                await notifier.setSelfDeafened(nextDeafened);
                await ref
                    .read(livekitVoiceProvider.notifier)
                    .setDeafened(nextDeafened);
              },
            ),
            // ── Canvas/Spotlight toggle ──
            _buildDockItem(
              context,
              icon: spotlightMode ? Icons.grid_view : Icons.people,
              tooltip: spotlightMode ? 'Canvas view' : 'Spotlight view',
              isActive: spotlightMode,
              activeColor: context.accent,
              onPressed: onToggleSpotlight,
            ),
            _dockDivider(context),
            // ── Leave ──
            _buildDockItem(
              context,
              icon: Icons.call_end,
              tooltip: 'Leave',
              isActive: true,
              activeColor: EchoTheme.danger,
              isDestructive: true,
              onPressed: () async {
                if (screenShare.isScreenSharing) {
                  await ref
                      .read(livekitVoiceProvider.notifier)
                      .setScreenShareEnabled(false);
                  ref
                      .read(screenShareProvider.notifier)
                      .setLiveKitScreenShareActive(false);
                }
                await ref
                    .read(channelsProvider.notifier)
                    .leaveVoiceChannel(conversationId, channelId);
                await ref.read(livekitVoiceProvider.notifier).leaveChannel();
              },
            ),
          ],
        ),
      ),
    );
  }

  static Widget _dockDivider(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: context.border.withValues(alpha: 0.4),
    );
  }

  static Widget _buildDockItem(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    bool isActive = false,
    Color? activeColor,
    bool isDestructive = false,
    required VoidCallback onPressed,
  }) {
    final Color iconColor;
    if (isDestructive) {
      iconColor = activeColor ?? EchoTheme.danger;
    } else if (isActive) {
      iconColor = activeColor ?? context.accent;
    } else {
      iconColor = context.textSecondary;
    }

    final Color bgColor;
    if (isDestructive) {
      bgColor = (activeColor ?? EchoTheme.danger).withValues(alpha: 0.15);
    } else if (isActive) {
      bgColor = (activeColor ?? context.accent).withValues(alpha: 0.12);
    } else {
      bgColor = Colors.transparent;
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onPressed();
          },
          borderRadius: BorderRadius.circular(24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: iconColor),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dock button with paired 3-dot submenu
// ---------------------------------------------------------------------------

class _DockButtonWithSubmenu extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color? activeColor;
  final VoidCallback onPressed;
  final VoidCallback? onSubmenuTap;
  final bool submenuActive;
  final LayerLink? submenuLayerLink;

  const _DockButtonWithSubmenu({
    required this.icon,
    required this.tooltip,
    this.isActive = false,
    this.activeColor,
    required this.onPressed,
    this.onSubmenuTap,
    this.submenuActive = false,
    this.submenuLayerLink,
  });

  @override
  Widget build(BuildContext context) {
    final Color iconColor = isActive
        ? (activeColor ?? context.accent)
        : context.textSecondary;
    final Color bgColor = isActive
        ? (activeColor ?? context.accent).withValues(alpha: 0.12)
        : Colors.transparent;

    Widget? buildSubmenuTrigger() {
      if (onSubmenuTap == null) return null;
      final arrowColor = submenuActive
          ? (activeColor ?? context.accent)
          : context.textMuted;
      final arrowIcon = submenuActive ? Icons.expand_more : Icons.expand_less;
      final trigger = Tooltip(
        message: '$tooltip options',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onSubmenuTap!();
            },
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 20,
              height: 44,
              child: Icon(arrowIcon, size: 14, color: arrowColor),
            ),
          ),
        ),
      );

      if (submenuLayerLink != null) {
        return CompositedTransformTarget(
          link: submenuLayerLink!,
          child: trigger,
        );
      }
      return trigger;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                onPressed();
              },
              borderRadius: BorderRadius.circular(24),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
            ),
          ),
        ),
        if (onSubmenuTap != null) buildSubmenuTrigger()!,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Drawing tools non-modal panel
// ---------------------------------------------------------------------------

class _DrawingToolsPanel extends StatelessWidget {
  final Widget child;

  const _DrawingToolsPanel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 220),
      decoration: BoxDecoration(
        color: context.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Standalone submenu widgets (non-modal, used with CompositedTransformFollower)
// ---------------------------------------------------------------------------

class _MicSubmenuStandalone extends ConsumerWidget {
  final VoidCallback onRequestClose;

  const _MicSubmenuStandalone({required this.onRequestClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voiceSettings = ref.watch(voiceSettingsProvider);
    return SizedBox(
      width: 220,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Microphone',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          _toggleRow(
            context,
            label: 'Noise suppression',
            value: voiceSettings.noiseSuppression,
            onChanged: (v) async {
              await ref
                  .read(voiceSettingsProvider.notifier)
                  .setNoiseSuppression(v);
            },
          ),
          _toggleRow(
            context,
            label: 'Echo cancellation',
            value: voiceSettings.echoCancellation,
            onChanged: (v) async {
              await ref
                  .read(voiceSettingsProvider.notifier)
                  .setEchoCancellation(v);
            },
          ),
          _toggleRow(
            context,
            label: 'Auto gain control',
            value: voiceSettings.autoGainControl,
            onChanged: (v) async {
              await ref
                  .read(voiceSettingsProvider.notifier)
                  .setAutoGainControl(v);
            },
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _toggleRow(
    BuildContext context, {
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
            ),
            SizedBox(
              width: 36,
              height: 20,
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: context.accent,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraSubmenuStandalone extends ConsumerWidget {
  final VoidCallback onRequestClose;

  const _CameraSubmenuStandalone({required this.onRequestClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 240,
      child: FutureBuilder<List<MediaDeviceInfo>>(
        future: navigator.mediaDevices.enumerateDevices(),
        builder: (context, snapshot) {
          final currentCamId = ref.read(voiceSettingsProvider).cameraDeviceId;
          final devices = snapshot.data ?? [];
          final cameras = devices.where((d) => d.kind == 'videoinput').toList();

          if (cameras.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No cameras found',
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  'Camera',
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              ...cameras.map((cam) {
                final label = cam.label.isNotEmpty ? cam.label : cam.deviceId;
                final isCurrent = cam.deviceId == currentCamId;
                return InkWell(
                  onTap: () async {
                    if (cam.deviceId != currentCamId) {
                      await ref
                          .read(voiceSettingsProvider.notifier)
                          .setCameraDevice(cam.deviceId);
                      await ref
                          .read(livekitVoiceProvider.notifier)
                          .switchCamera();
                    }
                    onRequestClose();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isCurrent
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: isCurrent ? context.accent : context.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            label,
                            style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 13,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }
}

class _ScreenShareSubmenuStandalone extends ConsumerWidget {
  final VoidCallback onRequestClose;

  const _ScreenShareSubmenuStandalone({required this.onRequestClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ss = ref.watch(screenShareProvider);
    final voice = ref.watch(livekitVoiceProvider);
    final notifier = ref.read(livekitVoiceProvider.notifier);

    Future<void> applyPreset({required int bitrate, required int fps}) async {
      await notifier.setAutoQuality(false);
      await notifier.setVideoParams(bitrate: bitrate, fps: fps);
    }

    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Screen Share',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              ss.isScreenSharing ? 'Currently sharing' : 'Not sharing',
              style: TextStyle(
                color: ss.isScreenSharing
                    ? EchoTheme.online
                    : context.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(
              'Auto quality',
              style: TextStyle(color: context.textPrimary, fontSize: 13),
            ),
            value: voice.autoQuality,
            onChanged: (v) async {
              await notifier.setAutoQuality(v);
            },
          ),
          const Divider(height: 1),
          _qualityRow(
            context,
            label: 'Low (600 kbps, 15 fps)',
            selected:
                !voice.autoQuality &&
                voice.videoBitrate == 600000 &&
                voice.videoFps == 15,
            enabled: !voice.autoQuality,
            onTap: () => applyPreset(bitrate: 600000, fps: 15),
          ),
          _qualityRow(
            context,
            label: 'Balanced (1200 kbps, 24 fps)',
            selected:
                !voice.autoQuality &&
                voice.videoBitrate == 1200000 &&
                voice.videoFps == 24,
            enabled: !voice.autoQuality,
            onTap: () => applyPreset(bitrate: 1200000, fps: 24),
          ),
          _qualityRow(
            context,
            label: 'High (2000 kbps, 30 fps)',
            selected:
                !voice.autoQuality &&
                voice.videoBitrate == 2000000 &&
                voice.videoFps == 30,
            enabled: !voice.autoQuality,
            onTap: () => applyPreset(bitrate: 2000000, fps: 30),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _qualityRow(
    BuildContext context, {
    required String label,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color: enabled
                  ? (selected ? context.accent : context.textMuted)
                  : context.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? context.textPrimary
                      : context.textMuted.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Popup content for the drawing tools menu.
class _DrawingToolsMenu extends ConsumerStatefulWidget {
  final GlobalKey<LoungeDrawingCanvasState> drawingCanvasKey;
  final VoidCallback onToggleDrawing;
  final bool isDrawing;
  final String conversationId;
  final VoidCallback? onRequestClose;

  const _DrawingToolsMenu({
    required this.drawingCanvasKey,
    required this.onToggleDrawing,
    required this.isDrawing,
    required this.conversationId,
    this.onRequestClose,
  });

  @override
  ConsumerState<_DrawingToolsMenu> createState() => _DrawingToolsMenuState();
}

class _DrawingToolsMenuState extends ConsumerState<_DrawingToolsMenu> {
  DrawingTool _selectedTool = DrawingTool.pen;
  Color _selectedColor = Colors.white;
  double _selectedSize = 4.0;

  static final _rng = math.Random();

  static const _penColors = [
    Colors.white,
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.cyan,
    Colors.blue,
    Colors.purple,
    Colors.pink,
  ];

  static const _penSizes = [2.0, 4.0, 6.0, 10.0, 16.0];

  LoungeDrawingCanvasState? get _canvas => widget.drawingCanvasKey.currentState;

  @override
  void initState() {
    super.initState();
    final canvas = _canvas;
    if (canvas != null) {
      _selectedTool = canvas.tool;
      _selectedColor = canvas.penColor;
      _selectedSize = canvas.penSize;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tool selection
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                _toolChip(context, Icons.edit, 'Draw', DrawingTool.pen),
                const SizedBox(width: 8),
                _toolChip(
                  context,
                  Icons.auto_fix_high,
                  'Erase',
                  DrawingTool.eraser,
                ),
              ],
            ),
          ),
          if (_selectedTool == DrawingTool.pen) ...[
            const Divider(height: 1),
            // Color picker
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                'Color',
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _penColors.map((c) {
                  final isSelected = _selectedColor == c;
                  return GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _selectedColor = c);
                      _canvas?.setPenColor(c);
                      ref.read(canvasProvider.notifier).setColor(c);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: isSelected ? 24 : 20,
                      height: isSelected ? 24 : 20,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? context.accent : context.border,
                          width: isSelected ? 2.5 : 1,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: c.withValues(alpha: 0.5),
                                  blurRadius: 6,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 4),
            const Divider(height: 1),
            // Size picker
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                'Size',
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: _penSizes.map((s) {
                  final isSelected = _selectedSize == s;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedSize = s);
                        _canvas?.setPenSize(s);
                        ref.read(canvasProvider.notifier).setStrokeWidth(s);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected
                              ? context.accent.withValues(alpha: 0.12)
                              : Colors.transparent,
                          border: Border.all(
                            color: isSelected ? context.accent : context.border,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Center(
                          child: Container(
                            width: s.clamp(4.0, 16.0),
                            height: s.clamp(4.0, 16.0),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? context.accent
                                  : context.textPrimary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
          const Divider(height: 12),
          // Image + Paste + Clear + Stop
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () async {
                      HapticFeedback.lightImpact();
                      await _pickAndAddImage(context);
                      if (mounted) widget.onRequestClose?.call();
                    },
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 16,
                    ),
                    label: const Text('Image'),
                    style: TextButton.styleFrom(
                      foregroundColor: context.accent,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () async {
                      HapticFeedback.lightImpact();
                      await _pasteImageFromClipboard(context);
                      if (mounted) widget.onRequestClose?.call();
                    },
                    icon: const Icon(Icons.content_paste, size: 16),
                    label: const Text('Paste'),
                    style: TextButton.styleFrom(
                      foregroundColor: context.accent,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Clear + toggle drawing
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      _canvas?.clearMyDrawings();
                      ref.read(canvasProvider.notifier).clearDrawing();
                      widget.onRequestClose?.call();
                    },
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Clear'),
                    style: TextButton.styleFrom(
                      foregroundColor: EchoTheme.danger,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      widget.onToggleDrawing();
                      widget.onRequestClose?.call();
                    },
                    icon: Icon(
                      widget.isDrawing ? Icons.edit_off : Icons.edit,
                      size: 16,
                    ),
                    label: Text(widget.isDrawing ? 'Stop' : 'Draw'),
                    style: TextButton.styleFrom(
                      foregroundColor: context.textSecondary,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Open the system file picker to select an image and add it to the canvas.
  Future<void> _pickAndAddImage(BuildContext ctx) async {
    // Capture widget/ref values before any await so they remain valid if the
    // state is disposed while the file picker or upload is in progress.
    final conversationId = widget.conversationId;
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return;

      if (conversationId.isEmpty) {
        // No conversation — display locally only.
        _canvas?.addImageFromBytes(bytes);
        return;
      }

      if (token == null) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(content: Text('Sign in required to upload image')),
          );
        }
        return;
      }

      final ext = file.extension?.toLowerCase() ?? 'png';
      final mimeType = _mimeForExtension(ext);
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverUrl/api/media/upload'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['conversation_id'] = conversationId;
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: file.name,
          contentType: MediaType.parse(mimeType),
        ),
      );

      final response = await request.send();
      if (!mounted) return;
      final body = await response.stream.bytesToString();
      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final relUrl = data['url'] as String? ?? '';
        final absUrl = relUrl.startsWith('http') ? relUrl : '$serverUrl$relUrl';
        _addImageByUrl(absUrl);
      } else {
        // Upload failed — display locally via bytes only.
        _canvas?.addImageFromBytes(bytes);
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(
              content: Text('Image upload failed; shown locally only'),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[DrawingMenu] pickImage error: $e');
      if (ctx.mounted) {
        ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(const SnackBar(content: Text('Failed to add image')));
      }
    }
  }

  /// Read a URL from the clipboard and add it as a canvas image.
  Future<void> _pasteImageFromClipboard(BuildContext ctx) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text?.trim() ?? '';
      if (text.startsWith('http://') || text.startsWith('https://')) {
        _addImageByUrl(text);
        return;
      }
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text('Clipboard does not contain an image URL'),
          ),
        );
      }
    } catch (e) {
      debugPrint('[DrawingMenu] pasteClipboard error: $e');
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Failed to paste from clipboard')),
        );
      }
    }
  }

  void _addImageByUrl(String url) {
    if (!mounted) return;
    _canvas?.addImageFromUrl(url);
    final img = CanvasImage(
      id: newCanvasId(),
      url: url,
      x: 0.2 + _rng.nextDouble() * 0.3,
      y: 0.2 + _rng.nextDouble() * 0.3,
      width: 0.25,
      height: 0.25,
    );
    ref.read(canvasProvider.notifier).addImage(img);
  }

  static String _mimeForExtension(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/png';
    }
  }

  Widget _toolChip(
    BuildContext context,
    IconData icon,
    String label,
    DrawingTool tool,
  ) {
    final isSelected = _selectedTool == tool;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selectedTool = tool);
          _canvas?.setTool(tool);
          ref
              .read(canvasProvider.notifier)
              .setTool(
                tool == DrawingTool.eraser ? CanvasTool.eraser : CanvasTool.pen,
              );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? context.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? context.accent : context.border,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? context.accent : context.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? context.accent : context.textPrimary,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Draggable + resizable screen share window on the canvas
// ---------------------------------------------------------------------------

class _DraggableScreenShareWindow extends StatefulWidget {
  final double initialTop;
  final double initialRight;
  final String label;
  final bool isLocal;
  final Widget child;

  const _DraggableScreenShareWindow({
    super.key,
    this.initialTop = 16,
    this.initialRight = 16,
    required this.label,
    this.isLocal = false,
    required this.child,
  });

  @override
  State<_DraggableScreenShareWindow> createState() =>
      _DraggableScreenShareWindowState();
}

class _DraggableScreenShareWindowState
    extends State<_DraggableScreenShareWindow> {
  late double _top;
  late double _left;
  double _width = 320;
  double _height = 180;
  bool _positioned = false;

  static const double _minWidth = 160;
  static const double _minHeight = 90;

  @override
  void initState() {
    super.initState();
    _top = widget.initialTop;
    _left = 0; // Will be calculated in build
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        if (!_positioned) {
          _left = constraints.maxWidth - widget.initialRight - _width;
          _positioned = true;
        }
        // Clamp position within bounds
        _left = _left.clamp(0, constraints.maxWidth - 60);
        _top = _top.clamp(0, constraints.maxHeight - 40);

        return Positioned(
          left: _left,
          top: _top,
          child: GestureDetector(
            onPanUpdate: (d) {
              setState(() {
                _left += d.delta.dx;
                _top += d.delta.dy;
              });
            },
            child: Container(
              width: _width,
              height: _height,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: (widget.isLocal ? EchoTheme.danger : EchoTheme.accent)
                      .withValues(alpha: 0.6),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned.fill(child: widget.child),
                  // Label badge
                  Positioned(
                    top: 6,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.screen_share,
                            size: 11,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            widget.label,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Resize handle (bottom-right corner)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onPanUpdate: (d) {
                        setState(() {
                          _width = (_width + d.delta.dx).clamp(
                            _minWidth,
                            constraints.maxWidth - _left,
                          );
                          _height = (_height + d.delta.dy).clamp(
                            _minHeight,
                            constraints.maxHeight - _top,
                          );
                        });
                      },
                      child: Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.bottomRight,
                        child: Icon(
                          Icons.open_in_full,
                          size: 12,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Fullscreen video overlay
// ---------------------------------------------------------------------------

/// Full-screen page for a single video stream.
///
/// Hides system UI (status bar + navigation bar) while active.
/// Tap anywhere to close and restore system UI.
class _FullscreenVideoPage extends StatefulWidget {
  final lk.VideoTrack track;
  final bool mirror;

  const _FullscreenVideoPage({required this.track, this.mirror = false});

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: lk.VideoTrackRenderer(
          widget.track,
          fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          mirrorMode: widget.mirror
              ? lk.VideoViewMirrorMode.mirror
              : lk.VideoViewMirrorMode.off,
        ),
      ),
    );
  }
}
