import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/channels_provider.dart';
import '../providers/voice_rtc_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';

/// Compact voice control dock above the user status bar.
///
/// Single row: status indicator + channel name + mute/deafen/hangup.
class VoiceDock extends ConsumerWidget {
  final double width;

  const VoiceDock({super.key, this.width = 320});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voiceLk = ref.watch(voiceRtcProvider);

    if (!voiceLk.isActive || voiceLk.channelId == null) {
      return const SizedBox.shrink();
    }

    final voiceSettings = ref.watch(voiceSettingsProvider);
    final channelsState = ref.watch(channelsProvider);
    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId!;

    final channels = channelsState.channelsFor(conversationId);
    final activeChannel = channels.where((c) => c.id == channelId).firstOrNull;
    final channelName = activeChannel?.name ?? 'Voice';
    final peerCount = voiceLk.peerConnectionStates.length;

    final statusColor = voiceLk.isJoining
        ? context.textMuted
        : peerCount > 0
        ? EchoTheme.online
        : Colors.orange;

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
                  voiceLk.isJoining
                      ? 'Connecting...'
                      : peerCount > 0
                      ? 'Voice Connected'
                      : 'Waiting for peers',
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
          // Mute
          _DockIconButton(
            icon: voiceSettings.selfMuted ? Icons.mic_off : Icons.mic,
            color: voiceSettings.selfMuted
                ? EchoTheme.danger
                : context.textSecondary,
            tooltip: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
            onPressed: () async {
              final notifier = ref.read(voiceSettingsProvider.notifier);
              final nextMuted = !voiceSettings.selfMuted;
              await notifier.setSelfMuted(nextMuted);
              ref
                  .read(voiceRtcProvider.notifier)
                  .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
            },
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
              ref.read(voiceRtcProvider.notifier).setDeafened(nextDeafened);
            },
          ),
          // Hangup
          _DockIconButton(
            icon: Icons.call_end,
            color: EchoTheme.danger,
            tooltip: 'Leave',
            onPressed: () async {
              // Leave both server-side voice membership and local WebRTC state
              // so channel selection state clears consistently in the UI.
              await ref
                  .read(channelsProvider.notifier)
                  .leaveVoiceChannel(conversationId, channelId);
              await ref.read(voiceRtcProvider.notifier).leaveChannel();
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
