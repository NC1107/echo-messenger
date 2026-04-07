import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/channels_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';

/// Compact voice control dock above the user status bar.
///
/// Single row: status indicator + channel name + mute/deafen/hangup.
class VoiceDock extends ConsumerWidget {
  final double width;

  const VoiceDock({super.key, this.width = 320});

  static String _voiceStatusLabel(bool isJoining, int peerCount) {
    if (isJoining) return 'Connecting...';
    if (peerCount > 0) return 'Voice Connected';
    return 'Waiting for peers';
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

    if (!voiceLk.isActive || voiceLk.channelId == null) {
      return const SizedBox.shrink();
    }

    final voiceSettings = ref.watch(voiceSettingsProvider);
    final channelsState = ref.watch(channelsProvider);
    final screenShare = ref.watch(screenShareProvider);
    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId!;

    final channels = channelsState.channelsFor(conversationId);
    final activeChannel = channels.where((c) => c.id == channelId).firstOrNull;
    final channelName = activeChannel?.name ?? 'Voice';
    final peerCount = voiceLk.peerConnectionStates.length;

    final Color statusColor;
    if (voiceLk.isJoining) {
      statusColor = context.textMuted;
    } else if (peerCount > 0) {
      statusColor = EchoTheme.online;
    } else {
      statusColor = Colors.orange;
    }

    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(
          top: BorderSide(color: context.border, width: 1),
          right: BorderSide(color: context.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Status indicator + channel name
          Icon(Icons.graphic_eq, size: 14, color: statusColor),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _voiceStatusLabel(voiceLk.isJoining, peerCount),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '$channelName \u00b7 $peerCount peer(s)',
                  style: TextStyle(color: context.textMuted, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Video toggle
          _DockIconButton(
            icon: voiceLk.isVideoEnabled ? Icons.videocam : Icons.videocam_off,
            color: voiceLk.isVideoEnabled
                ? context.accent
                : context.textSecondary,
            tooltip: voiceLk.isVideoEnabled
                ? 'Turn off camera'
                : 'Turn on camera',
            onPressed: () async {
              await ref.read(livekitVoiceProvider.notifier).toggleVideo();
            },
          ),
          // Mute
          _DockIconButton(
            icon: voiceSettings.selfMuted || voiceSettings.selfDeafened
                ? Icons.mic_off
                : Icons.mic,
            color: voiceSettings.selfMuted
                ? EchoTheme.danger
                : voiceSettings.selfDeafened
                ? context.textMuted
                : context.textSecondary,
            tooltip: voiceSettings.selfDeafened
                ? 'Muted by deafen'
                : voiceSettings.selfMuted
                ? 'Unmute'
                : 'Mute',
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextMuted = !voiceSettings.selfMuted;
              await notifier.setSelfMuted(nextMuted);
              ref
                  .read(voiceRtcProvider.notifier)
                  .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
            },
          ),
          // Mic level indicator
          if (!voiceSettings.selfMuted && !voiceSettings.selfDeafened)
            AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width:
                  (ref.watch(
                            livekitVoiceProvider.select(
                              (s) => s.localAudioLevel,
                            ),
                          ) *
                          40)
                      .clamp(0.0, 40.0),
              height: 4,
              decoration: BoxDecoration(
                color: EchoTheme.online,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          // Deafen
          _DockIconButton(
            icon: voiceSettings.selfDeafened
                ? Icons.headset_off
                : Icons.headset,
            color: voiceSettings.selfDeafened
                ? EchoTheme.danger
                : context.textSecondary,
            tooltip: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextDeafened = !voiceSettings.selfDeafened;
              await notifier.setSelfDeafened(nextDeafened);
              // setDeafened controls remote audio playback, not mic
              await ref
                  .read(voiceRtcProvider.notifier)
                  .setDeafened(nextDeafened);
            },
          ),
          // Screen share (desktop / web only, published via LiveKit SDK)
          if (_supportsScreenShare)
            _DockIconButton(
              icon: screenShare.isScreenSharing
                  ? Icons.stop_screen_share
                  : Icons.screen_share,
              color: screenShare.isScreenSharing
                  ? EchoTheme.online
                  : context.textSecondary,
              tooltip: screenShare.isScreenSharing
                  ? 'Stop sharing'
                  : 'Share screen',
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
          // Hangup
          _DockIconButton(
            icon: Icons.call_end,
            color: EchoTheme.danger,
            tooltip: 'Leave',
            onPressed: () async {
              // Stop screen sharing when leaving the channel.
              if (screenShare.isScreenSharing) {
                await ref.read(screenShareProvider.notifier).stopScreenShare();
              }
              // Leave both server-side voice membership and local WebRTC state
              // so channel selection state clears consistently in the UI.
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

class _DockIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const _DockIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}
