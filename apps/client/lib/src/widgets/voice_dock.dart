import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' show ConnectionQuality;

import '../providers/channels_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../providers/screen_share_provider.dart';
import '../screens/voice_lounge/screen_share_actions.dart';
import '../providers/theme_provider.dart' show UIDensity, uiDensityProvider;
import '../providers/voice_settings_provider.dart';
import '../theme/echo_theme.dart';

/// 1Hz wall-clock notifier shared by every active voice dock so the call
/// duration label can refresh without rebuilding the whole dock subtree.
/// Started lazily on first listener attach and cancelled when the last
/// listener detaches — no work while the user is idle.
final _voiceClock = _SecondsClockNotifier();

class _SecondsClockNotifier extends ValueNotifier<DateTime> {
  _SecondsClockNotifier() : super(DateTime.now());

  Timer? _timer;
  int _listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      value = DateTime.now();
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount--;
    assert(_listenerCount >= 0);
    if (_listenerCount == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

String _formatCallDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Compact voice control dock above the user status bar.
///
/// Single row: status indicator + channel name + mute/deafen/hangup.
class VoiceDock extends ConsumerWidget {
  final double width;
  final VoidCallback? onNavigateToLounge;
  final bool collapsed;

  const VoiceDock({
    super.key,
    this.width = 320,
    this.onNavigateToLounge,
    this.collapsed = false,
  });

  static String _qualityLabel(ConnectionQuality q) => switch (q) {
    ConnectionQuality.excellent => 'Excellent',
    ConnectionQuality.good => 'Good',
    ConnectionQuality.poor => 'Poor',
    ConnectionQuality.lost => 'Lost',
    ConnectionQuality.unknown => 'Unknown',
  };

  static Color _qualityColor(BuildContext context, ConnectionQuality q) =>
      switch (q) {
        ConnectionQuality.excellent => EchoTheme.online,
        ConnectionQuality.good => context.accent,
        ConnectionQuality.poor => EchoTheme.warning,
        ConnectionQuality.lost => EchoTheme.danger,
        ConnectionQuality.unknown => context.textMuted,
      };

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

    final spec = (
      context: context,
      ref: ref,
      voiceLk: voiceLk,
      voiceSettings: voiceSettings,
      screenShare: screenShare,
      conversationId: conversationId,
      channelId: channelId,
      m: m,
    );

    if (collapsed) {
      final compactSpec = (
        context: context,
        ref: ref,
        voiceLk: voiceLk,
        voiceSettings: voiceSettings,
        screenShare: screenShare,
        conversationId: conversationId,
        channelId: channelId,
        m: _DockMetrics.compact,
      );
      return _buildCollapsedDock(compactSpec, statusColor);
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onNavigateToLounge,
      child: Container(
        width: width,
        padding: EdgeInsets.symmetric(horizontal: m.hPad, vertical: m.vPad),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(8),
            bottom: Radius.circular(8),
          ),
          border: Border(
            top: BorderSide(color: context.border, width: 1),
            right: BorderSide(color: context.border, width: 1),
            bottom: BorderSide(color: context.border, width: 1),
            left: BorderSide(color: context.border, width: 1),
          ),
        ),
        child: Row(
          children: [
            _buildStatusLabel(
              spec,
              statusColor,
              voiceLk.isJoining,
              peerCount,
              channelName,
              voiceLk.localConnectionQuality,
              voiceLk.callStartedAt,
            ),
            ..._buildControlButtons(spec),
          ],
        ),
      ),
    );
  }

  /// Compact vertical dock for the 60px collapsed sidebar.
  Widget _buildCollapsedDock(_DockButtonSpec spec, Color statusColor) {
    final context = spec.context;
    final ref = spec.ref;
    final voiceLk = spec.voiceLk;
    final voiceSettings = spec.voiceSettings;
    final screenShare = spec.screenShare;
    final conversationId = spec.conversationId;
    final channelId = spec.channelId;
    final m = spec.m;
    final callStartedAt = voiceLk.callStartedAt;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onNavigateToLounge,
      child: Container(
        width: 60,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(8),
            bottom: Radius.circular(8),
          ),
          border: Border(
            top: BorderSide(color: context.border, width: 1),
            right: BorderSide(color: context.border, width: 1),
            bottom: BorderSide(color: context.border, width: 1),
            left: BorderSide(color: context.border, width: 1),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            if (callStartedAt != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: ValueListenableBuilder<DateTime>(
                  valueListenable: _voiceClock,
                  builder: (context, now, _) {
                    final elapsed = now.difference(callStartedAt);
                    final label = _formatCallDuration(
                      elapsed.isNegative ? Duration.zero : elapsed,
                    );
                    return Text(
                      label,
                      style: TextStyle(
                        color: context.textMuted,
                        fontSize: 9,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      textAlign: TextAlign.center,
                    );
                  },
                ),
              ),
            _buildMuteButton(context, ref, voiceSettings, m),
            _buildDeafenButton(context, ref, voiceSettings, m),
            _buildHangupButton(
              context,
              ref,
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
    return EchoTheme.warning;
  }

  /// Status indicator icon + channel name / peer count.
  Widget _buildStatusLabel(
    _DockButtonSpec spec,
    Color statusColor,
    bool isJoining,
    int peerCount,
    String channelName,
    ConnectionQuality quality,
    DateTime? callStartedAt,
  ) {
    return Expanded(
      child: Row(
        children: [
          Icon(
            Icons.graphic_eq,
            size: spec.m.statusIconSize,
            color: statusColor,
          ),
          if (quality != ConnectionQuality.unknown) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: 'Connection: ${_qualityLabel(quality)}',
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _qualityColor(spec.context, quality),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
          SizedBox(width: spec.m.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _voiceStatusLabel(isJoining, peerCount),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: spec.m.statusBigFontSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _SecondaryStatusLine(
                  channelName: channelName,
                  peerCount: peerCount,
                  callStartedAt: callStartedAt,
                  fontSize: spec.m.statusSmallFontSize,
                  color: spec.context.textMuted,
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
  List<Widget> _buildControlButtons(_DockButtonSpec spec) {
    return [
      _buildVideoButton(spec.context, spec.ref, spec.voiceLk, spec.m),
      _buildMuteButton(spec.context, spec.ref, spec.voiceSettings, spec.m),
      _buildDeafenButton(spec.context, spec.ref, spec.voiceSettings, spec.m),
      if (_supportsScreenShare)
        _buildScreenShareButton(
          spec.context,
          spec.ref,
          spec.screenShare,
          spec.m,
        ),
      _buildHangupButton(
        spec.context,
        spec.ref,
        spec.screenShare,
        spec.conversationId,
        spec.channelId,
        spec.m,
      ),
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
      onPressed: () => toggleScreenShare(context, ref),
    );
  }

  Widget _buildHangupButton(
    BuildContext context,
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
        // Call the shared helper instead of bare setScreenShareEnabled(false)
        // so that Linux portal cleanup (removePublishedTrack + track.stop +
        // track.dispose) runs before disconnect. Guard with the sharing flag
        // so toggleScreenShare only takes the stop-sharing branch, never the
        // start-sharing branch.
        if (screenShare.isScreenSharing) {
          await toggleScreenShare(context, ref);
        }
        await ref
            .read(channelsProvider.notifier)
            .leaveVoiceChannel(conversationId, channelId);
        await ref.read(livekitVoiceProvider.notifier).leaveChannel();
      },
    );
  }
}

/// Parameters for dock button construction, reducing parameter counts from 8 to 2.
typedef _DockButtonSpec = ({
  BuildContext context,
  WidgetRef ref,
  LiveKitVoiceState voiceLk,
  VoiceSettingsState voiceSettings,
  ScreenShareState screenShare,
  String conversationId,
  String channelId,
  _DockMetrics m,
});

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

/// Secondary status row showing `channel · N peers` and, once the call has
/// successfully connected, an M:SS call-duration tag. The duration label is
/// driven by [_voiceClock] via a [ValueListenableBuilder] so only this small
/// subtree rebuilds every second — the rest of the dock stays static.
class _SecondaryStatusLine extends StatelessWidget {
  final String channelName;
  final int peerCount;
  final DateTime? callStartedAt;
  final double fontSize;
  final Color color;

  const _SecondaryStatusLine({
    required this.channelName,
    required this.peerCount,
    required this.callStartedAt,
    required this.fontSize,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final base =
        '$channelName · $peerCount ${peerCount == 1 ? 'peer' : 'peers'}';
    final style = TextStyle(color: color, fontSize: fontSize);

    if (callStartedAt == null) {
      return Text(base, style: style, overflow: TextOverflow.ellipsis);
    }

    return ValueListenableBuilder<DateTime>(
      valueListenable: _voiceClock,
      builder: (context, now, _) {
        final elapsed = now.difference(callStartedAt!);
        final duration = _formatCallDuration(
          elapsed.isNegative ? Duration.zero : elapsed,
        );
        return Text(
          '$base · $duration',
          style: style,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
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
        onTap: () {
          HapticFeedback.lightImpact();
          onPressed();
        },
        borderRadius: BorderRadius.circular(EchoRadii.md),
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
