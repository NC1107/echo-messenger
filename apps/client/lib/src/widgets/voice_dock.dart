import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/voice_livekit_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';

/// Discord-style voice control dock fixed at the bottom-left of the screen.
///
/// Displays the active voice channel name, peer count, and mute/deafen/leave
/// controls. Only visible when the user is in a voice channel.
class VoiceDock extends ConsumerWidget {
  final double width;

  const VoiceDock({super.key, this.width = 320});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voiceLk = ref.watch(voiceLivekitProvider);

    if (!voiceLk.isActive || voiceLk.channelId == null) {
      return const SizedBox.shrink();
    }

    final voiceSettings = ref.watch(voiceSettingsProvider);
    final channelsState = ref.watch(channelsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';
    final conversationId = voiceLk.conversationId ?? '';
    final channelId = voiceLk.channelId!;

    final channels = channelsState.channelsFor(conversationId);
    final activeChannel = channels.where((c) => c.id == channelId).firstOrNull;
    final channelName = activeChannel?.name ?? 'Voice';
    final participants = channelsState.voiceSessionsFor(channelId);
    final peerCount = voiceLk.participantIds.length;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(
          top: BorderSide(color: context.border, width: 1),
          right: BorderSide(color: context.border, width: 1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Channel info row
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Row(
              children: [
                Icon(Icons.graphic_eq, size: 16, color: EchoTheme.online),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Voice Connected',
                        style: TextStyle(
                          color: EchoTheme.online,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '$channelName -- $peerCount peer(s)',
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (voiceLk.isJoining)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.accent,
                      ),
                    ),
                  ),
                if (participants.any((p) => p.userId == myUserId))
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.fiber_manual_record,
                      size: 10,
                      color: EchoTheme.online,
                    ),
                  ),
              ],
            ),
          ),
          // Controls row
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
            child: Row(
              children: [
                // Mute
                IconButton(
                  icon: Icon(
                    voiceSettings.selfMuted ? Icons.mic_off : Icons.mic,
                    size: 18,
                  ),
                  color: voiceSettings.selfMuted
                      ? EchoTheme.danger
                      : context.textSecondary,
                  tooltip: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
                  onPressed: () async {
                    final notifier = ref.read(voiceSettingsProvider.notifier);
                    final nextMuted = !voiceSettings.selfMuted;
                    await notifier.setSelfMuted(nextMuted);
                    ref
                        .read(voiceLivekitProvider.notifier)
                        .setCaptureEnabled(
                          !nextMuted && !voiceSettings.selfDeafened,
                        );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
                // Deafen
                IconButton(
                  icon: Icon(
                    voiceSettings.selfDeafened
                        ? Icons.volume_off_outlined
                        : Icons.volume_up_outlined,
                    size: 18,
                  ),
                  color: voiceSettings.selfDeafened
                      ? EchoTheme.danger
                      : context.textSecondary,
                  tooltip: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
                  onPressed: () async {
                    final notifier = ref.read(voiceSettingsProvider.notifier);
                    final nextDeafened = !voiceSettings.selfDeafened;
                    await notifier.setSelfDeafened(nextDeafened);
                    final lk = ref.read(voiceLivekitProvider.notifier);
                    lk.setCaptureEnabled(
                      !voiceSettings.selfMuted && !nextDeafened,
                    );
                    await lk.setDeafened(nextDeafened);
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
                const Spacer(),
                // Disconnect
                Tooltip(
                  message: 'Disconnect',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        ref.read(voiceLivekitProvider.notifier).leaveChannel();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: EchoTheme.danger.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.call_end,
                              size: 16,
                              color: EchoTheme.danger,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Leave',
                              style: TextStyle(
                                color: EchoTheme.danger,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
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
}
