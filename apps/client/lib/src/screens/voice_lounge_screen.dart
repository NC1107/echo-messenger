import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:cached_network_image/cached_network_image.dart';

import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';

/// Discord-style voice lounge that replaces the chat content area when the
/// user is in a voice call and chooses to view the lounge.
class VoiceLoungeScreen extends ConsumerWidget {
  /// Called when the user taps "Back to chat".
  final VoidCallback? onBackToChat;

  const VoiceLoungeScreen({super.key, this.onBackToChat});

  static String? _buildAvatarUrl(WidgetRef ref) {
    final avatarPath = ref.read(authProvider).avatarUrl;
    if (avatarPath == null || avatarPath.isEmpty) return null;
    final serverUrl = ref.read(serverUrlProvider);
    return '$serverUrl$avatarPath';
  }

  /// Screen sharing is only useful on desktop and web platforms.
  static bool get _supportsScreenShare {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return Container(
      color: context.mainBg,
      child: Column(
        children: [
          // Header
          _LoungeHeader(
            channelName: channelName,
            participantCount: totalParticipants,
            onBackToChat: onBackToChat,
          ),
          // Main content area
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Screen share viewer (large, above participants)
                  if (screenShare.isScreenSharing) _ScreenShareViewer(ref: ref),
                  if (screenShare.isScreenSharing) const SizedBox(height: 16),
                  // Remote screen shares
                  if (room != null) _RemoteScreenShares(room: room),
                  // Participant grid
                  _ParticipantGrid(
                    room: room,
                    voiceState: voiceLk,
                    localAvatarUrl: _buildAvatarUrl(ref),
                  ),
                ],
              ),
            ),
          ),
          // Control bar
          _ControlBar(
            voiceState: voiceLk,
            voiceSettings: voiceSettings,
            screenShare: screenShare,
            conversationId: conversationId,
            channelId: channelId,
          ),
        ],
      ),
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
          Icon(Icons.graphic_eq, size: 20, color: EchoTheme.online),
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

  const _ParticipantGrid({
    required this.room,
    required this.voiceState,
    this.localAvatarUrl,
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

      tiles.add(
        _ParticipantTile(
          key: const ValueKey('local'),
          name: 'You',
          avatarUrl: localAvatarUrl,
          hasVideo: localVideo?.track != null,
          videoTrack: localVideo?.track as lk.VideoTrack?,
          mirror: true,
          audioLevel: voiceState.localAudioLevel,
          isMuted: !voiceState.isCaptureEnabled,
        ),
      );
    }

    // Remote participant tiles
    for (final participant in room!.remoteParticipants.values) {
      final displayName = participant.name.isNotEmpty
          ? participant.name
          : participant.identity.isNotEmpty
          ? participant.identity
          : participant.sid.toString();

      final videoTrack = participant.videoTrackPublications
          .where(
            (pub) =>
                pub.track != null &&
                pub.track is lk.VideoTrack &&
                pub.source == lk.TrackSource.camera,
          )
          .firstOrNull;

      // Audio levels are keyed by identity (UUID), not display name.
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
    final crossAxisCount = tiles.length <= 1
        ? 1
        : tiles.length <= 4
        ? 2
        : 3;

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

  const _ParticipantTile({
    super.key,
    required this.name,
    this.avatarUrl,
    required this.hasVideo,
    this.videoTrack,
    this.mirror = false,
    this.audioLevel = 0.0,
    this.isMuted = false,
  });

  @override
  Widget build(BuildContext context) {
    final isSpeaking = audioLevel > 0.01;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSpeaking ? EchoTheme.online : context.border,
          width: isSpeaking ? 2.0 : 1.0,
        ),
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
    final renderer = ref.read(screenShareProvider.notifier).screenRenderer;
    if (renderer == null) return const SizedBox.shrink();

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
              child: RTCVideoView(
                renderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
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
                await ref.read(screenShareProvider.notifier).stopScreenShare();
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

  const _RemoteScreenShares({required this.room});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];

    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.videoTrackPublications) {
        if (pub.track != null &&
            pub.track is lk.VideoTrack &&
            pub.source == lk.TrackSource.screenShareVideo) {
          final identity = participant.identity.isNotEmpty
              ? participant.identity
              : participant.sid.toString();
          tiles.add(
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 400),
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
                            '$identity\'s screen',
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
                ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Mute
          _ControlButton(
            icon: voiceSettings.selfMuted ? Icons.mic_off : Icons.mic,
            label: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
            isActive: voiceSettings.selfMuted,
            activeColor: EchoTheme.danger,
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextMuted = !voiceSettings.selfMuted;
              await notifier.setSelfMuted(nextMuted);
              ref
                  .read(livekitVoiceProvider.notifier)
                  .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
            },
          ),
          const SizedBox(width: 8),
          // Deafen
          _ControlButton(
            icon: voiceSettings.selfDeafened
                ? Icons.headset_off
                : Icons.headset,
            label: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
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
          const SizedBox(width: 8),
          // Video
          _ControlButton(
            icon: voiceState.isVideoEnabled
                ? Icons.videocam
                : Icons.videocam_off,
            label: voiceState.isVideoEnabled ? 'Camera On' : 'Camera',
            isActive: voiceState.isVideoEnabled,
            activeColor: context.accent,
            onPressed: () async {
              await ref.read(livekitVoiceProvider.notifier).toggleVideo();
            },
          ),
          const SizedBox(width: 8),
          // Screen share (published via LiveKit SDK)
          if (VoiceLoungeScreen._supportsScreenShare) ...[
            _ControlButton(
              icon: screenShare.isScreenSharing
                  ? Icons.stop_screen_share
                  : Icons.screen_share,
              label: screenShare.isScreenSharing ? 'Stop Share' : 'Share',
              isActive: screenShare.isScreenSharing,
              activeColor: EchoTheme.online,
              onPressed: () async {
                final lkNotifier = ref.read(livekitVoiceProvider.notifier);
                final ssNotifier = ref.read(screenShareProvider.notifier);
                if (screenShare.isScreenSharing) {
                  await lkNotifier.setScreenShareEnabled(false);
                  await ssNotifier.stopScreenShare();
                } else {
                  final ok = await lkNotifier.setScreenShareEnabled(true);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not start screen sharing.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                }
              },
            ),
            const SizedBox(width: 8),
          ],
          // Hangup
          _ControlButton(
            icon: Icons.call_end,
            label: 'Leave',
            isActive: true,
            activeColor: EchoTheme.danger,
            isDestructive: true,
            onPressed: () async {
              if (screenShare.isScreenSharing) {
                await ref
                    .read(livekitVoiceProvider.notifier)
                    .setScreenShareEnabled(false);
                await ref.read(screenShareProvider.notifier).stopScreenShare();
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
// Control button
// ---------------------------------------------------------------------------

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final bool isDestructive;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onPressed,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isDestructive
        ? activeColor.withValues(alpha: 0.2)
        : isActive
        ? activeColor.withValues(alpha: 0.15)
        : context.surfaceHover;
    final iconColor = isDestructive
        ? activeColor
        : isActive
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: iconColor),
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
            ),
          ),
        ),
      ),
    );
  }
}
