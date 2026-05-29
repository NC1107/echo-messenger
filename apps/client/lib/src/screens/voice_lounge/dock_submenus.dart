/// Standalone submenu widgets used by the floating dock.
///
/// Each submenu is rendered via [CompositedTransformFollower] anchored to its
/// dock button — no modal route, no barrier.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../providers/livekit_voice/livekit_voice_provider.dart';
import '../../providers/livekit_voice/stream_quality_preset.dart';
import '../../providers/screen_share_provider.dart';
import '../../providers/voice_settings_provider.dart';
import '../../theme/echo_theme.dart';

class MicSubmenuStandalone extends ConsumerWidget {
  final VoidCallback onRequestClose;

  const MicSubmenuStandalone({super.key, required this.onRequestClose});

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

class CameraSubmenuStandalone extends ConsumerWidget {
  final VoidCallback onRequestClose;

  const CameraSubmenuStandalone({super.key, required this.onRequestClose});

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
              ..._buildCameraOptions(context, ref, cameras, currentCamId),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildCameraOptions(
    BuildContext context,
    WidgetRef ref,
    List<MediaDeviceInfo> cameras,
    String currentCamId,
  ) {
    return cameras.map((cam) {
      final label = cam.label.isNotEmpty ? cam.label : cam.deviceId;
      final isCurrent = cam.deviceId == currentCamId;
      return InkWell(
        onTap: () async {
          if (cam.deviceId != currentCamId) {
            await ref
                .read(voiceSettingsProvider.notifier)
                .setCameraDevice(cam.deviceId);
            await ref.read(livekitVoiceProvider.notifier).switchCamera();
          }
          onRequestClose();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}

class ScreenShareSubmenuStandalone extends ConsumerWidget {
  final VoidCallback onRequestClose;

  const ScreenShareSubmenuStandalone({super.key, required this.onRequestClose});

  // Ordered list of manual preset tiers shown in the picker.
  static const List<StreamQuality> _manualPresets = [
    StreamQuality.sd,
    StreamQuality.hd,
    StreamQuality.fullHd,
    StreamQuality.ultra,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ss = ref.watch(screenShareProvider);
    final voice = ref.watch(livekitVoiceProvider);
    final voiceNotifier = ref.read(livekitVoiceProvider.notifier);
    final settingsNotifier = ref.read(voiceSettingsProvider.notifier);
    final chosenPreset = ref.watch(
      voiceSettingsProvider.select((s) => s.streamQualityPreset),
    );

    Future<void> applyPreset(StreamQuality preset) async {
      await settingsNotifier.setStreamQualityPreset(preset);
      await voiceNotifier.setAutoQuality(false);
      final params = kStreamQualityParams[preset]!;
      await voiceNotifier.setVideoParams(
        bitrate: params.bitrate,
        fps: params.fps,
      );
    }

    Future<void> enableAuto() async {
      await settingsNotifier.setStreamQualityPreset(StreamQuality.auto);
      await voiceNotifier.setAutoQuality(true);
    }

    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, ss),
          const SizedBox(height: 6),
          _buildAutoToggle(
            context,
            voice,
            enableAuto,
            applyPreset,
            chosenPreset,
          ),
          const Divider(height: 1),
          ..._buildPresetRows(context, voice, chosenPreset, applyPreset),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ScreenShareState ss) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
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
      ],
    );
  }

  Widget _buildAutoToggle(
    BuildContext context,
    LiveKitVoiceState voice,
    Future<void> Function() enableAuto,
    Future<void> Function(StreamQuality) applyPreset,
    StreamQuality chosenPreset,
  ) {
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Semantics(
        label: 'Auto quality toggle',
        child: Text(
          'Auto quality',
          style: TextStyle(color: context.textPrimary, fontSize: 13),
        ),
      ),
      value: voice.autoQuality,
      onChanged: (v) async {
        if (v) {
          await enableAuto();
        } else {
          // Re-apply the last manually chosen preset (or HD if none set yet).
          final target = chosenPreset == StreamQuality.auto
              ? StreamQuality.hd
              : chosenPreset;
          await applyPreset(target);
        }
      },
    );
  }

  List<Widget> _buildPresetRows(
    BuildContext context,
    LiveKitVoiceState voice,
    StreamQuality chosenPreset,
    Future<void> Function(StreamQuality) applyPreset,
  ) {
    return _manualPresets.map((preset) {
      final params = kStreamQualityParams[preset]!;
      final kbps = params.bitrate ~/ 1000;
      final label =
          '${kStreamQualityLabel[preset]} ($kbps kbps, ${params.fps} fps)';
      final isSelected = !voice.autoQuality && chosenPreset == preset;
      return _QualityRow(
        label: label,
        semanticLabel: '${kStreamQualityLabel[preset]} quality preset',
        selected: isSelected,
        enabled: !voice.autoQuality,
        accent: context.accent,
        onTap: () => applyPreset(preset),
      );
    }).toList();
  }
}

class _QualityRow extends StatelessWidget {
  final String label;
  final String semanticLabel;
  final bool selected;
  final bool enabled;
  final Color accent;
  final VoidCallback onTap;

  const _QualityRow({
    required this.label,
    required this.semanticLabel,
    required this.selected,
    required this.enabled,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radioColor = _radioColor(context);
    final textColor = enabled
        ? context.textPrimary
        : context.textMuted.withValues(alpha: 0.7);

    return Semantics(
      label: semanticLabel,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 16,
                color: radioColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: textColor, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _radioColor(BuildContext context) {
    if (!enabled) return context.textMuted.withValues(alpha: 0.5);
    return selected ? accent : context.textMuted;
  }
}
