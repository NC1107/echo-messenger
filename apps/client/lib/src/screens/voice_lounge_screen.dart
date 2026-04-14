import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/lounge_drawing_canvas.dart';
import '../widgets/vertex_mesh_background.dart';
import '../utils/canvas_utils.dart';
import '../widgets/voice_canvas.dart';

const _kScreenshareLocal = 'screenshare-local';

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

  /// Whether the current platform supports camera switching (front/back).
  static bool get _supportsCameraFlip {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
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

  /// When true and any screen share is active, the immersive 3-layer AR view
  /// is shown instead of the classic spotlight layout.
  /// The user can toggle back with the focus button in either view.
  bool _immersiveMode = true;

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
    final hasAnyShare = hasRemoteShare || screenShare.isScreenSharing;

    if (hasAnyShare) {
      if (_immersiveMode) {
        return _buildImmersiveLayout(
          room: room,
          voiceLk: voiceLk,
          screenShare: screenShare,
        );
      }
      if (hasRemoteShare) {
        return _buildSpotlightLayout(
          room: room!,
          voiceLk: voiceLk,
          screenShare: screenShare,
          memberAvatars: memberAvatars,
        );
      }
    }

    // Default: voice-lounge canvas (movable avatars + drawing + images).
    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId ?? '';

    if (conversationId.isNotEmpty && channelId.isNotEmpty) {
      return Stack(
        children: [
          VoiceCanvas(
            channelId: channelId,
            conversationId: conversationId,
            room: room,
            voiceState: voiceLk,
            localAvatarUrl: _buildAvatarUrl(),
          ),
          // Local screen-share preview (floating, tap to focus)
          if (screenShare.isScreenSharing)
            Positioned(
              top: 16,
              right: 16,
              width: 180,
              height: 100,
              child: GestureDetector(
                onTap: () =>
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

  /// Spotlight layout: auto-triggered when a remote screen share is active.
  Widget _buildSpotlightLayout({
    required lk.Room room,
    required LiveKitVoiceState voiceLk,
    required ScreenShareState screenShare,
    required Map<String, String?> memberAvatars,
  }) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Screen share fills all available space
              Expanded(
                child: _RemoteScreenShares(
                  room: room,
                  spotlight: true,
                  onTileTap: (sid) =>
                      setState(() => _focusedTileKey = 'screenshare-$sid'),
                ),
              ),
              // Local screen share viewer (tap to focus)
              if (screenShare.isScreenSharing) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () =>
                      setState(() => _focusedTileKey = _kScreenshareLocal),
                  child: SizedBox(
                    height: 120,
                    child: _ScreenShareViewer(ref: ref),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              // Compact participant strip
              SizedBox(
                height: 80,
                child: _ParticipantGrid(
                  room: room,
                  voiceState: voiceLk,
                  localAvatarUrl: _buildAvatarUrl(),
                  compact: true,
                  onTileTap: (key) => setState(() => _focusedTileKey = key),
                ),
              ),
            ],
          ),
        ),
        // Switch to immersive AR view
        Positioned(
          top: 8,
          right: 8,
          child: _ImmersiveModeButton(
            immersive: false,
            onTap: () => setState(() => _immersiveMode = true),
          ),
        ),
      ],
    );
  }

  /// Immersive 3-layer AR-style screen-share view.
  ///
  /// Layer 0 (back)  — Parallax vertex-mesh background that shifts subtly
  ///                    as the cursor / finger moves around the screen.
  /// Layer 1 (mid)   — Frosted-glass participant drawer anchored at the
  ///                    bottom; tap the handle to expand / collapse.
  /// Layer 2 (front) — Zoomable screen-share tiles + profile icon bubbles.
  ///
  /// A "Classic layout" toggle in the top-right corner reverts to the
  /// traditional spotlight view.
  Widget _buildImmersiveLayout({
    required lk.Room? room,
    required LiveKitVoiceState voiceLk,
    required ScreenShareState screenShare,
  }) {
    final avatarUrl = _buildAvatarUrl();
    return _ParallaxContainer(
      builder: (context, parallaxOffset) {
        return Stack(
          children: [
            // ── Layer 0: parallax background ────────────────────────────────
            Positioned.fill(
              child: Transform.translate(
                offset: parallaxOffset,
                child: VertexMeshBackground(
                  accentColor: context.accent,
                  backgroundColor: context.mainBg,
                  vertexCount: 28,
                ),
              ),
            ),

            // ── Layer 2: zoomable screen-share tiles + profile icons ─────────
            // (rendered before the glass drawer so the drawer sits on top)
            Positioned(
              left: 12,
              right: 12,
              top: 8,
              bottom: _GlassParticipantDrawer.collapsedHeight + 8,
              child: _ZoomableScreenShareGrid(
                room: room,
                screenShare: screenShare,
                voiceLk: voiceLk,
                localAvatarUrl: avatarUrl,
                onFocus: (key) => setState(() => _focusedTileKey = key),
              ),
            ),

            // ── Layer 1: glass participant drawer ────────────────────────────
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _GlassParticipantDrawer(
                room: room,
                voiceLk: voiceLk,
                localAvatarUrl: avatarUrl,
                onTileTap: (key) => setState(() => _focusedTileKey = key),
              ),
            ),

            // ── Focus toggle: switch back to classic layout ──────────────────
            Positioned(
              top: 8,
              right: 8,
              child: _ImmersiveModeButton(
                immersive: true,
                onTap: () => setState(() => _immersiveMode = false),
              ),
            ),
          ],
        );
      },
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
      drawingCanvasKey: _drawingCanvasKey,
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
                  Positioned.fill(child: drawingOverlay),
                  Positioned(bottom: 16, left: 0, right: 0, child: dock),
                  Positioned(
                    top: 12,
                    left: 12,
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
                Positioned.fill(child: drawingOverlay),
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
// Remote screen shares
// ---------------------------------------------------------------------------

class _RemoteScreenShares extends StatelessWidget {
  final lk.Room room;
  final bool spotlight;

  /// Called with the participant SID when the user taps a screen share tile.
  final void Function(String participantSid)? onTileTap;

  const _RemoteScreenShares({
    required this.room,
    this.spotlight = false,
    this.onTileTap,
  });

  /// Build a single screen share tile for a participant.
  Widget _buildScreenShareTile(
    BuildContext context,
    lk.RemoteParticipant participant,
    lk.VideoTrack track,
  ) {
    final screenShareName = participantDisplayName(participant);
    final sid = participant.sid.toString();
    return GestureDetector(
      onTap: onTileTap != null ? () => onTileTap!(sid) : null,
      child: Container(
        width: double.infinity,
        constraints: spotlight ? null : const BoxConstraints(maxHeight: 400),
        margin: const EdgeInsets.only(bottom: 16),
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
                  track,
                  fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 12,
              child: _buildScreenShareBadge(context, screenShareName),
            ),
          ],
        ),
      ),
    );
  }

  /// Badge overlay for screen share tile (name + icon).
  Widget _buildScreenShareBadge(BuildContext context, String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.accent.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.screen_share, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            '$name\'s screen',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onTileTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.touch_app, size: 12, color: Colors.white54),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];

    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.videoTrackPublications) {
        if (pub.track != null &&
            pub.track is lk.VideoTrack &&
            pub.source == lk.TrackSource.screenShareVideo) {
          tiles.add(
            _buildScreenShareTile(
              context,
              participant,
              pub.track! as lk.VideoTrack,
            ),
          );
        }
      }
    }

    if (tiles.isEmpty) return const SizedBox.shrink();
    return Column(children: tiles);
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
  final GlobalKey<LoungeDrawingCanvasState> drawingCanvasKey;

  const _FloatingDock({
    required this.voiceState,
    required this.voiceSettings,
    required this.screenShare,
    required this.conversationId,
    required this.channelId,
    required this.isDrawing,
    required this.onToggleDrawing,
    required this.drawingCanvasKey,
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
            _buildDockItem(
              context,
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
            ),
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
            _buildDockItem(
              context,
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
            ),
            if (VoiceLoungeScreen._supportsCameraFlip &&
                voiceState.isVideoEnabled)
              _buildDockItem(
                context,
                icon: Icons.flip_camera_android,
                tooltip: 'Flip camera',
                onPressed: () async {
                  await ref.read(livekitVoiceProvider.notifier).switchCamera();
                },
              ),
            if (VoiceLoungeScreen._supportsScreenShare)
              _buildDockItem(
                context,
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
                    final ok = await lkNotifier.setScreenShareEnabled(true);
                    if (ok) {
                      ssNotifier.setLiveKitScreenShareActive(true);
                    }
                  }
                },
              ),
            _buildDrawToolItem(context, ref),
            _dockDivider(context),
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

  Widget _dockDivider(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: context.border.withValues(alpha: 0.4),
    );
  }

  Widget _buildDrawToolItem(BuildContext context, WidgetRef ref) {
    return _DrawingDockItem(
      isDrawing: isDrawing,
      onToggleDrawing: onToggleDrawing,
      drawingCanvasKey: drawingCanvasKey,
    );
  }

  Widget _buildDockItem(
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
          onTap: onPressed,
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
// Drawing dock item with popover tools menu
// ---------------------------------------------------------------------------

class _DrawingDockItem extends StatelessWidget {
  final bool isDrawing;
  final VoidCallback onToggleDrawing;
  final GlobalKey<LoungeDrawingCanvasState> drawingCanvasKey;

  const _DrawingDockItem({
    required this.isDrawing,
    required this.onToggleDrawing,
    required this.drawingCanvasKey,
  });

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

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: isDrawing ? 'Drawing tools' : 'Draw',
      offset: const Offset(0, -220),
      position: PopupMenuPosition.over,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.border),
      ),
      color: context.surface.withValues(alpha: 0.95),
      onOpened: () {
        if (!isDrawing) onToggleDrawing();
      },
      itemBuilder: (ctx) => [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _DrawingToolsMenu(
            drawingCanvasKey: drawingCanvasKey,
            onToggleDrawing: onToggleDrawing,
            isDrawing: isDrawing,
          ),
        ),
      ],
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isDrawing
              ? context.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.edit,
          size: 20,
          color: isDrawing ? context.accent : context.textSecondary,
        ),
      ),
    );
  }
}

/// Popup content for the drawing tools menu.
class _DrawingToolsMenu extends StatefulWidget {
  final GlobalKey<LoungeDrawingCanvasState> drawingCanvasKey;
  final VoidCallback onToggleDrawing;
  final bool isDrawing;

  const _DrawingToolsMenu({
    required this.drawingCanvasKey,
    required this.onToggleDrawing,
    required this.isDrawing,
  });

  @override
  State<_DrawingToolsMenu> createState() => _DrawingToolsMenuState();
}

class _DrawingToolsMenuState extends State<_DrawingToolsMenu> {
  DrawingTool _selectedTool = DrawingTool.pen;
  Color _selectedColor = Colors.white;
  double _selectedSize = 4.0;

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
                children: _DrawingDockItem._penColors.map((c) {
                  final isSelected = _selectedColor == c;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _selectedColor = c);
                      _canvas?.setPenColor(c);
                    },
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? context.accent : context.border,
                          width: isSelected ? 2 : 1,
                        ),
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
                children: _DrawingDockItem._penSizes.map((s) {
                  final isSelected = _selectedSize == s;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _selectedSize = s);
                        _canvas?.setPenSize(s);
                      },
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
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
                              color: context.textPrimary,
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
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showImageUrlDialog(context);
                    },
                    icon: const Icon(Icons.image, size: 16),
                    label: const Text('URL'),
                    style: TextButton.styleFrom(
                      foregroundColor: context.accent,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _canvas?.addImageFromClipboard();
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
                      _canvas?.clearMyDrawings();
                      Navigator.of(context).pop();
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
                      widget.onToggleDrawing();
                      Navigator.of(context).pop();
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

  void _showImageUrlDialog(BuildContext ctx) {
    final controller = TextEditingController();
    showDialog(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Paste Image URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://example.com/image.png',
          ),
          onSubmitted: (url) {
            if (url.trim().isNotEmpty) {
              _canvas?.addImageFromUrl(url.trim());
            }
            Navigator.of(dialogCtx).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                _canvas?.addImageFromUrl(url);
              }
              Navigator.of(dialogCtx).pop();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
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
          setState(() => _selectedTool = tool);
          _canvas?.setTool(tool);
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

// ---------------------------------------------------------------------------
// Immersive mode toggle button
// ---------------------------------------------------------------------------

/// Small chip that toggles between the immersive AR view and the classic
/// spotlight layout.  [immersive] reflects the *current* state so the label
/// indicates what the button will *switch to*.
class _ImmersiveModeButton extends StatelessWidget {
  final bool immersive;
  final VoidCallback onTap;

  const _ImmersiveModeButton({required this.immersive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: immersive
          ? 'Switch to classic layout'
          : 'Switch to immersive view',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                immersive ? Icons.grid_view : Icons.view_in_ar_outlined,
                size: 14,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                immersive ? 'Classic' : 'Immersive',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Parallax container — smooth cursor / touch-driven background offset
// ---------------------------------------------------------------------------

/// Wraps its [builder] in a pointer-tracking listener.  The [builder]
/// receives a smoothly-animated [Offset] that represents how far the
/// background should be shifted (max ±[_maxShift] pixels) in response to
/// cursor position or touch movement.
class _ParallaxContainer extends StatefulWidget {
  final Widget Function(BuildContext context, Offset parallaxOffset) builder;

  const _ParallaxContainer({required this.builder});

  @override
  State<_ParallaxContainer> createState() => _ParallaxContainerState();
}

class _ParallaxContainerState extends State<_ParallaxContainer>
    with SingleTickerProviderStateMixin {
  static const double _maxShift = 20.0;
  static const double _lerp = 0.07; // per tick, ~60 fps → ~4 fps effective lag

  Offset _target = Offset.zero;
  Offset _current = Offset.zero;
  late Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    final next = Offset.lerp(_current, _target, _lerp)!;
    if ((next - _current).distance > 0.05) {
      setState(() => _current = next);
    }
  }

  void _onPointerEvent(PointerEvent e, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final nx = (e.localPosition.dx / size.width) - 0.5; // [-0.5, 0.5]
    final ny = (e.localPosition.dy / size.height) - 0.5;
    _target = Offset(nx * _maxShift, ny * _maxShift);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerHover: (e) => _onPointerEvent(e, size),
          onPointerMove: (e) => _onPointerEvent(e, size),
          child: widget.builder(context, _current),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Glass participant drawer — Layer 1
// ---------------------------------------------------------------------------

/// Frosted-glass bottom drawer showing the participant strip.
/// Tap the drag-handle chip to toggle between collapsed and expanded.
class _GlassParticipantDrawer extends StatefulWidget {
  static const double collapsedHeight = 90.0;
  static const double expandedHeight = 190.0;

  final lk.Room? room;
  final LiveKitVoiceState voiceLk;
  final String? localAvatarUrl;
  final void Function(String key) onTileTap;

  const _GlassParticipantDrawer({
    required this.room,
    required this.voiceLk,
    required this.localAvatarUrl,
    required this.onTileTap,
  });

  @override
  State<_GlassParticipantDrawer> createState() =>
      _GlassParticipantDrawerState();
}

class _GlassParticipantDrawerState extends State<_GlassParticipantDrawer> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final h = _expanded
        ? _GlassParticipantDrawer.expandedHeight
        : _GlassParticipantDrawer.collapsedHeight;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        height: h,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.18),
                    width: 0.5,
                  ),
                ),
              ),
              child: Column(
                children: [
                  // ── drag handle ──────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  // ── compact participant strip (always visible) ────────────
                  SizedBox(
                    height: 62,
                    child: _ParticipantGrid(
                      room: widget.room,
                      voiceState: widget.voiceLk,
                      localAvatarUrl: widget.localAvatarUrl,
                      compact: true,
                      onTileTap: widget.onTileTap,
                    ),
                  ),
                  // ── expanded: second row shows full tiles ─────────────────
                  if (_expanded)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: 8,
                          right: 8,
                          top: 8,
                          bottom: 4,
                        ),
                        child: _ParticipantGrid(
                          room: widget.room,
                          voiceState: widget.voiceLk,
                          localAvatarUrl: widget.localAvatarUrl,
                          compact: false,
                          onTileTap: widget.onTileTap,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Zoomable screen-share grid — Layer 2
// ---------------------------------------------------------------------------

/// Arranges all active screen-share tiles (remote + local) into a grid or
/// single-tile layout.  Each tile supports pinch-to-zoom and double-tap zoom.
class _ZoomableScreenShareGrid extends StatelessWidget {
  final lk.Room? room;
  final ScreenShareState screenShare;
  final LiveKitVoiceState voiceLk;
  final String? localAvatarUrl;
  final void Function(String key) onFocus;

  const _ZoomableScreenShareGrid({
    required this.room,
    required this.screenShare,
    required this.voiceLk,
    required this.localAvatarUrl,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];

    // Remote screen shares
    if (room != null) {
      for (final p in room!.remoteParticipants.values) {
        for (final pub in p.videoTrackPublications) {
          if (pub.track != null &&
              pub.track is lk.VideoTrack &&
              pub.source == lk.TrackSource.screenShareVideo) {
            final track = pub.track! as lk.VideoTrack;
            final sid = p.sid.toString();
            tiles.add(
              _ZoomableScreenShareTile(
                key: ValueKey('ztile-$sid'),
                track: track,
                label: "${participantDisplayName(p)}'s screen",
                isLocal: false,
                onFocus: () => onFocus('screenshare-$sid'),
              ),
            );
          }
        }
      }
    }

    // Local screen share
    if (screenShare.isScreenSharing && room != null) {
      final pub = room!.localParticipant?.videoTrackPublications
          .where(
            (p) =>
                p.track != null && p.source == lk.TrackSource.screenShareVideo,
          )
          .firstOrNull;
      final localTrack = pub?.track as lk.VideoTrack?;
      if (localTrack != null) {
        tiles.add(
          _ZoomableScreenShareTile(
            key: const ValueKey('ztile-local'),
            track: localTrack,
            label: 'Your screen',
            isLocal: true,
            onFocus: () => onFocus(_kScreenshareLocal),
          ),
        );
      }
    }

    if (tiles.isEmpty) {
      return const Center(
        child: Icon(
          Icons.screen_share_outlined,
          size: 48,
          color: Colors.white24,
        ),
      );
    }

    if (tiles.length == 1) return tiles.first;

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      physics: const NeverScrollableScrollPhysics(),
      children: tiles,
    );
  }
}

// ---------------------------------------------------------------------------
// Zoomable screen-share tile
// ---------------------------------------------------------------------------

/// A single screen-share tile that supports:
///  • Pinch-to-zoom via [InteractiveViewer]
///  • Double-tap to zoom 2× at the tapped position (double-tap again to reset)
///  • A "Focus" button to enter the full-screen focused view
///  • A zoom-reset button when zoomed in
class _ZoomableScreenShareTile extends StatefulWidget {
  final lk.VideoTrack track;
  final String label;
  final bool isLocal;
  final VoidCallback onFocus;

  const _ZoomableScreenShareTile({
    super.key,
    required this.track,
    required this.label,
    required this.isLocal,
    required this.onFocus,
  });

  @override
  State<_ZoomableScreenShareTile> createState() =>
      _ZoomableScreenShareTileState();
}

class _ZoomableScreenShareTileState extends State<_ZoomableScreenShareTile> {
  final TransformationController _transformCtrl = TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_zoomed) {
      _transformCtrl.value = Matrix4.identity();
      setState(() => _zoomed = false);
      return;
    }
    const scale = 2.5;
    final pos = details.localPosition;
    final m = Matrix4.identity()
      ..translateByDouble(
        -pos.dx * (scale - 1),
        -pos.dy * (scale - 1),
        0.0,
        1.0,
      )
      ..scaleByDouble(scale, scale, 1.0, 1.0);
    _transformCtrl.value = m;
    setState(() => _zoomed = true);
  }

  void _resetZoom() {
    _transformCtrl.value = Matrix4.identity();
    setState(() => _zoomed = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Video + interactive zoom ─────────────────────────────────────
          GestureDetector(
            onDoubleTapDown: _onDoubleTapDown,
            child: InteractiveViewer(
              transformationController: _transformCtrl,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              minScale: 0.8,
              maxScale: 5.0,
              child: lk.VideoTrackRenderer(
                widget.track,
                fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
          ),

          // ── Name badge ───────────────────────────────────────────────────
          Positioned(
            top: 10,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (widget.isLocal ? EchoTheme.danger : EchoTheme.accent)
                    .withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.screen_share, size: 13, color: Colors.white),
                  const SizedBox(width: 5),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Overlay action buttons ───────────────────────────────────────
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_zoomed)
                  _overlayIconBtn(
                    icon: Icons.zoom_out,
                    tooltip: 'Reset zoom',
                    onTap: _resetZoom,
                  ),
                if (_zoomed) const SizedBox(width: 4),
                _overlayIconBtn(
                  icon: Icons.open_in_full,
                  tooltip: 'Focus',
                  onTap: widget.onFocus,
                ),
              ],
            ),
          ),

          // ── Zoom hint (shown when not zoomed) ────────────────────────────
          if (!_zoomed)
            Positioned(
              bottom: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Double-tap to zoom',
                  style: TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _overlayIconBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 0.5,
            ),
          ),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}
