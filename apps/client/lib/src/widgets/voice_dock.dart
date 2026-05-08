import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/channels_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../providers/theme_provider.dart' show UIDensity, uiDensityProvider;
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
    final density = ref.watch(uiDensityProvider);
    final m = _DockMetrics.forDensity(density);
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
        padding: EdgeInsets.symmetric(horizontal: m.hPad, vertical: m.vPad),
        decoration: BoxDecoration(
          color: context.surface,
          border: Border(
            top: BorderSide(color: context.border, width: 1),
            right: BorderSide(color: context.border, width: 1),
          ),
        ),
        child: Row(
          children: [
            _buildStatusLabel(
              context,
              statusColor,
              voiceLk.isJoining,
              peerCount,
              channelName,
              m,
            ),
            ..._buildControlButtons(
              context,
              ref,
              voiceLk,
              voiceSettings,
              screenShare,
              conversationId,
              channelId,
              m,
            ),
          ],
        ),
      ),
    );
  }

  static Color _statusColor(
    BuildContext context,
    bool isJoining,
    int peerCount,
  ) {
    if (isJoining) return context.textMuted;
    if (peerCount > 0) return EchoTheme.online;
    return Colors.orange;
  }

  /// Status indicator icon + channel name / peer count.
  Widget _buildStatusLabel(
    BuildContext context,
    Color statusColor,
    bool isJoining,
    int peerCount,
    String channelName,
    _DockMetrics m,
  ) {
    return Expanded(
      child: Row(
        children: [
          Icon(Icons.graphic_eq, size: m.statusIconSize, color: statusColor),
          SizedBox(width: m.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _voiceStatusLabel(isJoining, peerCount),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: m.statusBigFontSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '$channelName \u00b7 $peerCount ${peerCount == 1 ? 'peer' : 'peers'}',
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: m.statusSmallFontSize,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// All control icon buttons: video, mute, mic level, deafen, screen share,
  /// and hangup.
  List<Widget> _buildControlButtons(
    BuildContext context,
    WidgetRef ref,
    LiveKitVoiceState voiceLk,
    VoiceSettingsState voiceSettings,
    ScreenShareState screenShare,
    String conversationId,
    String channelId,
    _DockMetrics m,
  ) {
    return [
      _buildVideoButton(context, ref, voiceLk, m),
      _buildMuteButton(context, ref, voiceSettings, m),
      _buildMicLevelIndicator(ref, voiceSettings),
      _buildDeafenButton(context, ref, voiceSettings, m),
      if (_supportsScreenShare)
        _buildScreenShareButton(context, ref, screenShare, m),
      _buildHangupButton(ref, screenShare, conversationId, channelId, m),
    ];
  }

  Widget _buildVideoButton(
    BuildContext context,
    WidgetRef ref,
    LiveKitVoiceState voiceLk,
    _DockMetrics m,
  ) {
    return _DockIconButton(
      icon: voiceLk.isVideoEnabled ? Icons.videocam : Icons.videocam_off,
      color: voiceLk.isVideoEnabled ? context.accent : context.textSecondary,
      tooltip: voiceLk.isVideoEnabled ? 'Turn off camera' : 'Turn on camera',
      iconSize: m.btnIconSize,
      onPressed: () async {
        await ref.read(livekitVoiceProvider.notifier).toggleVideo();
      },
    );
  }

  Widget _buildMuteButton(
    BuildContext context,
    WidgetRef ref,
    VoiceSettingsState voiceSettings,
    _DockMetrics m,
  ) {
    return _DockIconButton(
      icon: voiceSettings.selfMuted || voiceSettings.selfDeafened
          ? Icons.mic_off
          : Icons.mic,
      color: _muteColor(context, voiceSettings),
      tooltip: _muteTooltip(voiceSettings),
      iconSize: m.btnIconSize,
      onPressed: () async {
        final notifier = ref.read(voiceSettingsProvider.notifier);
        final nextMuted = !voiceSettings.selfMuted;
        await notifier.setSelfMuted(nextMuted);
        ref
            .read(voiceRtcProvider.notifier)
            .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
      },
    );
  }

  Widget _buildMicLevelIndicator(
    WidgetRef ref,
    VoiceSettingsState voiceSettings,
  ) {
    if (voiceSettings.selfMuted || voiceSettings.selfDeafened) {
      return const SizedBox.shrink();
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      width:
          (ref.watch(livekitVoiceProvider.select((s) => s.localAudioLevel)) *
                  40)
              .clamp(0.0, 40.0),
      height: 4,
      decoration: BoxDecoration(
        color: EchoTheme.online,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildDeafenButton(
    BuildContext context,
    WidgetRef ref,
    VoiceSettingsState voiceSettings,
    _DockMetrics m,
  ) {
    return _DockIconButton(
      icon: voiceSettings.selfDeafened ? Icons.headset_off : Icons.headset,
      color: voiceSettings.selfDeafened
          ? EchoTheme.danger
          : context.textSecondary,
      tooltip: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
      iconSize: m.btnIconSize,
      onPressed: () async {
        final notifier = ref.read(voiceSettingsProvider.notifier);
        final nextDeafened = !voiceSettings.selfDeafened;
        await notifier.setSelfDeafened(nextDeafened);
        await ref.read(voiceRtcProvider.notifier).setDeafened(nextDeafened);
      },
    );
  }

  Widget _buildScreenShareButton(
    BuildContext context,
    WidgetRef ref,
    ScreenShareState screenShare,
    _DockMetrics m,
  ) {
    return _DockIconButton(
      icon: screenShare.isScreenSharing
          ? Icons.stop_screen_share
          : Icons.screen_share,
      color: screenShare.isScreenSharing
          ? EchoTheme.online
          : context.textSecondary,
      tooltip: screenShare.isScreenSharing ? 'Stop sharing' : 'Share screen',
      iconSize: m.btnIconSize,
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
    );
  }

  Widget _buildHangupButton(
    WidgetRef ref,
    ScreenShareState screenShare,
    String conversationId,
    String channelId,
    _DockMetrics m,
  ) {
    return _DockIconButton(
      icon: Icons.call_end,
      color: EchoTheme.danger,
      tooltip: 'Leave',
      iconSize: m.btnIconSize,
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
  final double iconSize;

  const _DockIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        // 44x44 hit target stays constant across density tiers (WCAG 2.5.5);
        // only the visual icon scales.
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(icon, size: iconSize, color: color),
          ),
        ),
      ),
    );
  }
}

class _DockMetrics {
  final double hPad;
  final double vPad;
  final double statusIconSize;
  final double gap;
  final double statusBigFontSize;
  final double statusSmallFontSize;
  final double btnIconSize;

  const _DockMetrics({
    required this.hPad,
    required this.vPad,
    required this.statusIconSize,
    required this.gap,
    required this.statusBigFontSize,
    required this.statusSmallFontSize,
    required this.btnIconSize,
  });

  static const cozy = _DockMetrics(
    hPad: 12,
    vPad: 10,
    statusIconSize: 16,
    gap: 8,
    statusBigFontSize: 12,
    statusSmallFontSize: 11,
    btnIconSize: 18,
  );
  static const normal = _DockMetrics(
    hPad: 10,
    vPad: 8,
    statusIconSize: 15,
    gap: 7,
    statusBigFontSize: 11,
    statusSmallFontSize: 10,
    btnIconSize: 17,
  );
  static const compact = _DockMetrics(
    hPad: 8,
    vPad: 6,
    statusIconSize: 14,
    gap: 6,
    statusBigFontSize: 11,
    statusSmallFontSize: 10,
    btnIconSize: 16,
  );

  static _DockMetrics forDensity(UIDensity d) {
    switch (d) {
      case UIDensity.cozy:
        return cozy;
      case UIDensity.normal:
        return normal;
      case UIDensity.compact:
        return compact;
    }
  }
}
