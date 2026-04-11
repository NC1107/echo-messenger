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
  final VoidCallback? onNavigateToLounge;

  const VoiceDock({super.key, this.width = 320, this.onNavigateToLounge});

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
    final statusColor = _statusColor(context, voiceLk.isJoining, peerCount);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onNavigateToLounge,
      child: Container(
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
            _buildStatusLabel(context, statusColor, voiceLk.isJoining,
                peerCount, channelName),
            ..._buildControlButtons(context, ref, voiceLk, voiceSettings,
                screenShare, conversationId, channelId),
          ],
        ),
      ),
    );
  }
}

Color _muteColor(BuildContext context, VoiceSettingsState vs) {
  if (vs.selfMuted) return EchoTheme.danger;
  if (vs.selfDeafened) return context.textMuted;
  return context.textSecondary;
}

String _muteTooltip(VoiceSettingsState vs) {
  if (vs.selfDeafened) return 'Muted by deafen';
  if (vs.selfMuted) return 'Unmute';
  return 'Mute';
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
