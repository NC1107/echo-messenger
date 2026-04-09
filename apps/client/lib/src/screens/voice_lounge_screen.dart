import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:cached_network_image/cached_network_image.dart';

import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';

/// Resolve a LiveKit participant's display name, preferring name > identity > sid.
String _participantDisplayName(lk.Participant participant) {
  if (participant.name.isNotEmpty) return participant.name;
  if (participant.identity.isNotEmpty) return participant.identity;
  return participant.sid.toString();
}

/// Discord-style voice lounge that replaces the chat content area when the
/// user is in a voice call and chooses to view the lounge.
class VoiceLoungeScreen extends ConsumerStatefulWidget {
  /// Called when the user taps "Back to chat".
  final VoidCallback? onBackToChat;

  const VoiceLoungeScreen({super.key, this.onBackToChat});

  /// Screen sharing is only useful on desktop and web platforms.
  static bool get _supportsScreenShare {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  ConsumerState<VoiceLoungeScreen> createState() => _VoiceLoungeScreenState();
}

class _VoiceLoungeScreenState extends ConsumerState<VoiceLoungeScreen> {
  /// Key of the tile currently in focus. Null = grid / auto-spotlight view.
  /// Format: 'local', 'remote-{sid}', 'screenshare-local', 'screenshare-{sid}'.
  String? _focusedTileKey;

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
    if (tileKey == 'screenshare-local') {
      final pub = room.localParticipant?.videoTrackPublications
          .where(
            (p) =>
                p.track != null &&
                p.source == lk.TrackSource.screenShareVideo,
          )
          .firstOrNull;
      return (pub?.track as lk.VideoTrack?, false);
    }
    if (tileKey.startsWith('screenshare-')) {
      final sid = tileKey.substring('screenshare-'.length);
      final participant = room.remoteParticipants.values
          .where((p) => p.sid.toString() == sid)
          .firstOrNull;
      if (participant == null) return (null, false);
      final pub = participant.videoTrackPublications
          .where(
            (p) =>
                p.track != null &&
                p.source == lk.TrackSource.screenShareVideo,
          )
          .firstOrNull;
      return (pub?.track as lk.VideoTrack?, false);
    }
    if (tileKey.startsWith('remote-')) {
      final sid = tileKey.substring('remote-'.length);
      final participant = room.remoteParticipants.values
          .where((p) => p.sid.toString() == sid)
          .firstOrNull;
      if (participant == null) return (null, false);
      final pub = participant.videoTrackPublications
          .where(
            (p) => p.track != null && p.source == lk.TrackSource.camera,
          )
          .firstOrNull;
      return (pub?.track as lk.VideoTrack?, false);
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

  /// Dispatches to focused view, auto-spotlight, or the default grid.
  Widget _buildContentArea({
    required lk.Room? room,
    required LiveKitVoiceState voiceLk,
    required ScreenShareState screenShare,
  }) {
    if (_focusedTileKey != null) {
      return _buildFocusedView(
        room: room,
        voiceLk: voiceLk,
        screenShare: screenShare,
      );
    }
    if (_hasActiveScreenShare(room)) {
      return _buildSpotlightLayout(
        room: room!,
        voiceLk: voiceLk,
        screenShare: screenShare,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (screenShare.isScreenSharing)
            GestureDetector(
              onTap: () =>
                  setState(() => _focusedTileKey = 'screenshare-local'),
              child: _ScreenShareViewer(ref: ref),
            ),
          if (screenShare.isScreenSharing) const SizedBox(height: 16),
          _ParticipantGrid(
            room: room,
            voiceState: voiceLk,
            localAvatarUrl: _buildAvatarUrl(),
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
  }) {
    return Padding(
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
                  setState(() => _focusedTileKey = 'screenshare-local'),
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
    );
  }

  /// Focused layout: the tapped stream fills the content area with a
  /// thumbnail strip below and close / fullscreen overlay buttons.
  Widget _buildFocusedView({
    required lk.Room? room,
    required LiveKitVoiceState voiceLk,
    required ScreenShareState screenShare,
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
                  child: Icon(
                    Icons.person,
                    size: 64,
                    color: Colors.white54,
                  ),
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

    final room = ref.read(livekitVoiceProvider.notifier).room;
    final totalParticipants = 1 + (room?.remoteParticipants.length ?? 0);

    final contentArea = _buildContentArea(
      room: room,
      voiceLk: voiceLk,
      screenShare: screenShare,
    );

    final controlBar = _ControlBar(
      voiceState: voiceLk,
      voiceSettings: voiceSettings,
      screenShare: screenShare,
      conversationId: conversationId,
      channelId: channelId,
    );

    return OrientationBuilder(
      builder: (context, orientation) {
        // In landscape: drop the 56-px header bar to maximise stream height,
        // replacing it with a small floating badge in the top-left corner.
        if (orientation == Orientation.landscape) {
          return Container(
            color: context.mainBg,
            child: Stack(
              children: [
                Column(
                  children: [
                    Expanded(child: contentArea),
                    controlBar,
                  ],
                ),
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
          );
        }

        // Portrait: full header bar + content + control bar
        return Container(
          color: context.mainBg,
          child: Column(
            children: [
              _LoungeHeader(
                channelName: channelName,
                participantCount: totalParticipants,
                onBackToChat: widget.onBackToChat,
              ),
              Expanded(child: contentArea),
              controlBar,
            ],
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
  final bool compact;
  /// Called with the tile key when the user taps a tile to focus it.
  final void Function(String key)? onTileTap;

  const _ParticipantGrid({
    required this.room,
    required this.voiceState,
    this.localAvatarUrl,
    this.compact = false,
    this.onTileTap,
  });

  @override
  Widget build(BuildContext context) {
    if (room == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            'Connecting to voice...',
            style: TextStyle(color: context.textMuted, fontSize: 14),
          ),
        ),
      );
    }

    final tiles = <Widget>[];

    // Local participant tile
    final localParticipant = room!.localParticipant;
    if (localParticipant != null) {
      final localVideo = localParticipant.videoTrackPublications
          .where(
            (pub) => pub.track != null && pub.source == lk.TrackSource.camera,
          )
          .firstOrNull;

      // Check both track existence AND the isVideoEnabled flag — the SDK
      // track publication may linger briefly after toggleVideo(false).
      final localHasVideo =
          localVideo?.track != null && voiceState.isVideoEnabled;
      tiles.add(
        _ParticipantTile(
          key: const ValueKey('local'),
          name: 'You',
          avatarUrl: localAvatarUrl,
          hasVideo: localHasVideo,
          videoTrack: localHasVideo
              ? localVideo?.track as lk.VideoTrack?
              : null,
          mirror: true,
          audioLevel: voiceState.localAudioLevel,
          isMuted: !voiceState.isCaptureEnabled,
          isLocal: true,
          onTap: onTileTap != null ? () => onTileTap!('local') : null,
        ),
      );
    }

    // Remote participant tiles
    for (final participant in room!.remoteParticipants.values) {
      final displayName = _participantDisplayName(participant);

      final videoTrack = participant.videoTrackPublications
          .where(
            (pub) =>
                pub.track != null &&
                pub.track is lk.VideoTrack &&
                pub.source == lk.TrackSource.camera,
          )
          .firstOrNull;

      // Audio levels are keyed by identity (now username, not UUID).
      final identity = participant.identity.isNotEmpty
          ? participant.identity
          : participant.sid.toString();
      final audioLevel = voiceState.peerAudioLevels[identity] ?? 0.0;

      tiles.add(
        _ParticipantTile(
          key: ValueKey('remote-${participant.sid}'),
          name: displayName.length > 16
              ? displayName.substring(0, 16)
              : displayName,
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
            // Toggle mute for this remote participant's audio tracks
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
        ),
      );
    }

    if (tiles.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            'No participants',
            style: TextStyle(color: context.textMuted, fontSize: 14),
          ),
        ),
      );
    }

    // Responsive grid: 1 col for 1, 2 cols for 2-4, 3 cols for 5+
    final int crossAxisCount;
    if (tiles.length <= 1) {
      crossAxisCount = 1;
    } else if (tiles.length <= 4) {
      crossAxisCount = 2;
    } else {
      crossAxisCount = 3;
    }

    // Compact mode: horizontal strip for spotlight layout
    if (compact) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tiles.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (_, i) => SizedBox(width: 100, child: tiles[i]),
      );
    }

    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 4 / 3,
      children: tiles,
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
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
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
            // Name label overlay at bottom
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.7),
                    ],
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
                        child: Icon(
                          Icons.mic_off,
                          size: 14,
                          color: EchoTheme.danger,
                        ),
                      ),
                    if (connectionState != null &&
                        connectionState != 'connected')
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
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: avatarColor,
          border: Border.all(
            color: isSpeaking ? EchoTheme.online : Colors.transparent,
            width: 3,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: avatarUrl != null
            ? CachedNetworkImage(
                imageUrl: avatarUrl!,
                fit: BoxFit.cover,
                width: 72,
                height: 72,
                placeholder: (_, _) => Center(
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                errorWidget: (_, _, _) => Center(
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
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
                    fontSize: 28,
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

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];

    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.videoTrackPublications) {
        if (pub.track != null &&
            pub.track is lk.VideoTrack &&
            pub.source == lk.TrackSource.screenShareVideo) {
          final screenShareName = _participantDisplayName(participant);
          final sid = participant.sid.toString();
          tiles.add(
            GestureDetector(
              onTap: onTileTap != null ? () => onTileTap!(sid) : null,
              child: Container(
                width: double.infinity,
                constraints: spotlight
                    ? null
                    : const BoxConstraints(maxHeight: 400),
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
                          pub.track! as lk.VideoTrack,
                          fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: context.accent.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.screen_share,
                              size: 14,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$screenShareName\'s screen',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (onTileTap != null) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.touch_app,
                                size: 12,
                                color: Colors.white54,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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
// Control bar
// ---------------------------------------------------------------------------

class _ControlBar extends ConsumerWidget {
  final LiveKitVoiceState voiceState;
  final VoiceSettingsState voiceSettings;
  final ScreenShareState screenShare;
  final String conversationId;
  final String channelId;

  const _ControlBar({
    required this.voiceState,
    required this.voiceSettings,
    required this.screenShare,
    required this.conversationId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // On narrow screens (width < 600) or in landscape, save space with
    // icon-only buttons at 44 px touch targets (no text labels).
    final isCompact = MediaQuery.of(context).size.width < 600 ||
        MediaQuery.of(context).orientation == Orientation.landscape;

    final gap = isCompact ? const SizedBox(width: 4) : const SizedBox(width: 8);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 8 : 16,
        vertical: isCompact ? 10 : 12,
      ),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: isCompact
            ? MainAxisAlignment.spaceEvenly
            : MainAxisAlignment.center,
        children: [
          // Mute (split: main toggles mute, dots open audio processing)
          _SplitControlButton(
            icon: voiceSettings.selfMuted ? Icons.mic_off : Icons.mic,
            label: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
            isActive: voiceSettings.selfMuted,
            activeColor: EchoTheme.danger,
            isCompact: isCompact,
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextMuted = !voiceSettings.selfMuted;
              await notifier.setSelfMuted(nextMuted);
              ref
                  .read(livekitVoiceProvider.notifier)
                  .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
            },
            menuBuilder: (context) =>
                _AudioProcessingMenu(voiceSettings: voiceSettings, ref: ref),
          ),
          gap,
          // Deafen (no split -- simple button)
          _ControlButton(
            icon: voiceSettings.selfDeafened
                ? Icons.headset_off
                : Icons.headset,
            label: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
            isActive: voiceSettings.selfDeafened,
            activeColor: EchoTheme.danger,
            isCompact: isCompact,
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextDeafened = !voiceSettings.selfDeafened;
              await notifier.setSelfDeafened(nextDeafened);
              await ref
                  .read(livekitVoiceProvider.notifier)
                  .setDeafened(nextDeafened);
            },
          ),
          gap,
          // Camera (split: main toggles camera, dots open bitrate/fps/auto)
          _SplitControlButton(
            icon: voiceState.isVideoEnabled
                ? Icons.videocam
                : Icons.videocam_off,
            label: voiceState.isVideoEnabled ? 'Camera On' : 'Camera',
            isActive: voiceState.isVideoEnabled,
            activeColor: context.accent,
            isCompact: isCompact,
            onPressed: () async {
              await ref.read(livekitVoiceProvider.notifier).toggleVideo();
            },
            menuBuilder: (context) =>
                _VideoSettingsMenu(voiceState: voiceState, ref: ref),
          ),
          // Screen share (split: main toggles share, dots open bitrate/fps)
          // Hidden entirely on platforms that don't support screen share.
          if (VoiceLoungeScreen._supportsScreenShare) ...[
            gap,
            _SplitControlButton(
              icon: screenShare.isScreenSharing
                  ? Icons.stop_screen_share
                  : Icons.screen_share,
              label: screenShare.isScreenSharing ? 'Stop Share' : 'Share',
              isActive: screenShare.isScreenSharing,
              activeColor: EchoTheme.online,
              isCompact: isCompact,
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
                  } else if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not start screen sharing.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                }
              },
              menuBuilder: (context) =>
                  _VideoSettingsMenu(voiceState: voiceState, ref: ref),
            ),
          ],
          gap,
          // Hangup
          _ControlButton(
            icon: Icons.call_end,
            label: 'Leave',
            isActive: true,
            activeColor: EchoTheme.danger,
            isDestructive: true,
            isCompact: isCompact,
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
    );
  }
}

// ---------------------------------------------------------------------------
// Split control button -- main action area + 3-dot menu
// ---------------------------------------------------------------------------

class _SplitControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final bool isCompact;
  final VoidCallback onPressed;
  final Widget Function(BuildContext context) menuBuilder;

  const _SplitControlButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onPressed,
    required this.menuBuilder,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color bgColor;
    if (isActive) {
      bgColor = activeColor.withValues(alpha: 0.15);
    } else {
      bgColor = context.surfaceHover;
    }
    final iconColor = isActive ? activeColor : context.textSecondary;

    return Tooltip(
      message: label,
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(24),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Main action area
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onPressed,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(24),
                  bottomLeft: Radius.circular(24),
                ),
                child: Padding(
                  padding: isCompact
                      ? const EdgeInsets.only(
                          left: 12,
                          right: 6,
                          top: 12,
                          bottom: 12,
                        )
                      : const EdgeInsets.only(
                          left: 16,
                          right: 8,
                          top: 10,
                          bottom: 10,
                        ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 20, color: iconColor),
                      if (!isCompact) ...[
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: TextStyle(
                            color: iconColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            // Divider
            Container(
              width: 1,
              height: 24,
              color: iconColor.withValues(alpha: 0.2),
            ),
            // 3-dot menu
            _SplitMenuAnchor(iconColor: iconColor, menuBuilder: menuBuilder),
          ],
        ),
      ),
    );
  }
}

/// The 3-dot icon that opens a popup menu via [PopupMenuButton].
class _SplitMenuAnchor extends StatelessWidget {
  final Color iconColor;
  final Widget Function(BuildContext context) menuBuilder;

  const _SplitMenuAnchor({required this.iconColor, required this.menuBuilder});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'Settings',
      offset: const Offset(0, -8),
      position: PopupMenuPosition.over,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.border),
      ),
      color: context.surface,
      itemBuilder: (ctx) => [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: menuBuilder(ctx),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 10, top: 10, bottom: 10),
        child: Icon(Icons.more_vert, size: 18, color: iconColor),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Video / screen share settings menu content
// ---------------------------------------------------------------------------

class _VideoSettingsMenu extends StatelessWidget {
  final LiveKitVoiceState voiceState;
  final WidgetRef ref;

  const _VideoSettingsMenu({required this.voiceState, required this.ref});

  static const _bitrateOptions = [
    (250000, '250 kbps'),
    (500000, '500 kbps'),
    (1000000, '1000 kbps'),
    (2000000, '2000 kbps'),
    (4000000, '4000 kbps'),
  ];

  static const _fpsOptions = [
    (15, '15 fps'),
    (24, '24 fps'),
    (30, '30 fps'),
    (60, '60 fps'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Auto quality toggle
          _MenuToggleRow(
            label: 'Auto Quality',
            value: voiceState.autoQuality,
            onChanged: (v) {
              ref.read(livekitVoiceProvider.notifier).setAutoQuality(v);
              Navigator.of(context).pop();
            },
          ),
          const Divider(height: 1),
          // Bitrate section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'Bitrate',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ..._bitrateOptions.map(
            (opt) => _MenuRadioRow(
              label: opt.$2,
              selected: voiceState.videoBitrate == opt.$1,
              enabled: !voiceState.autoQuality,
              onTap: () {
                ref
                    .read(livekitVoiceProvider.notifier)
                    .setVideoParams(bitrate: opt.$1);
                Navigator.of(context).pop();
              },
            ),
          ),
          const Divider(height: 1),
          // FPS section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'FPS',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ..._fpsOptions.map(
            (opt) => _MenuRadioRow(
              label: opt.$2,
              selected: voiceState.videoFps == opt.$1,
              enabled: !voiceState.autoQuality,
              onTap: () {
                ref
                    .read(livekitVoiceProvider.notifier)
                    .setVideoParams(fps: opt.$1);
                Navigator.of(context).pop();
              },
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Audio processing settings menu content
// ---------------------------------------------------------------------------

class _AudioProcessingMenu extends StatelessWidget {
  final VoiceSettingsState voiceSettings;
  final WidgetRef ref;

  const _AudioProcessingMenu({required this.voiceSettings, required this.ref});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'Audio Processing',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _MenuToggleRow(
            label: 'Noise Suppression',
            value: voiceSettings.noiseSuppression,
            onChanged: (v) {
              ref.read(voiceSettingsProvider.notifier).setNoiseSuppression(v);
              Navigator.of(context).pop();
            },
          ),
          _MenuToggleRow(
            label: 'Echo Cancellation',
            value: voiceSettings.echoCancellation,
            onChanged: (v) {
              ref.read(voiceSettingsProvider.notifier).setEchoCancellation(v);
              Navigator.of(context).pop();
            },
          ),
          _MenuToggleRow(
            label: 'Auto Gain Control',
            value: voiceSettings.autoGainControl,
            onChanged: (v) {
              ref.read(voiceSettingsProvider.notifier).setAutoGainControl(v);
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Menu helper widgets
// ---------------------------------------------------------------------------

/// A row with a label and a toggle switch for popup menu content.
class _MenuToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _MenuToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
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
              height: 20,
              width: 36,
              child: Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A radio-style row for popup menu content.
class _MenuRadioRow extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _MenuRadioRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final Color textColor;
    if (!enabled) {
      textColor = context.textMuted;
    } else if (selected) {
      textColor = context.accent;
    } else {
      textColor = context.textPrimary;
    }

    final Color iconColor;
    if (!enabled) {
      iconColor = context.textMuted;
    } else if (selected) {
      iconColor = context.accent;
    } else {
      iconColor = context.textMuted;
    }

    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color: iconColor,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Control button (simple, no split)
// ---------------------------------------------------------------------------

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final bool isDestructive;
  final bool isCompact;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onPressed,
    this.isDestructive = false,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color bgColor;
    if (isDestructive) {
      bgColor = activeColor.withValues(alpha: 0.2);
    } else if (isActive) {
      bgColor = activeColor.withValues(alpha: 0.15);
    } else {
      bgColor = context.surfaceHover;
    }
    final iconColor = (isDestructive || isActive)
        ? activeColor
        : context.textSecondary;

    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: isCompact
                ? const EdgeInsets.all(12)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: iconColor),
                if (!isCompact) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: iconColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
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
