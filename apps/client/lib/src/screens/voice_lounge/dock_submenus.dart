/// Standalone submenu widgets used by the floating dock.
///
/// Each submenu is rendered via [CompositedTransformFollower] anchored to its
/// dock button — no modal route, no barrier.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../providers/livekit_voice_provider.dart';
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
              ...cameras.map((cam) {
                final label = cam.label.isNotEmpty ? cam.label : cam.deviceId;
                final isCurrent = cam.deviceId == currentCamId;
                return InkWell(
                  onTap: () async {
                    if (cam.deviceId != currentCamId) {
                      await ref
                          .read(voiceSettingsProvider.notifier)
                          .setCameraDevice(cam.deviceId);
                      await ref
                          .read(livekitVoiceProvider.notifier)
                          .switchCamera();
                    }
                    onRequestClose();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
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
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }
}

class ScreenShareSubmenuStandalone extends ConsumerWidget {
  final VoidCallback onRequestClose;

  const ScreenShareSubmenuStandalone({super.key, required this.onRequestClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ss = ref.watch(screenShareProvider);
    final voice = ref.watch(livekitVoiceProvider);
    final notifier = ref.read(livekitVoiceProvider.notifier);

    Future<void> applyPreset({required int bitrate, required int fps}) async {
      await notifier.setAutoQuality(false);
      await notifier.setVideoParams(bitrate: bitrate, fps: fps);
    }

    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
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
          const SizedBox(height: 6),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(
              'Auto quality',
              style: TextStyle(color: context.textPrimary, fontSize: 13),
            ),
            value: voice.autoQuality,
            onChanged: (v) async {
              await notifier.setAutoQuality(v);
            },
          ),
          const Divider(height: 1),
          _qualityRow(
            context,
            label: 'Low (600 kbps, 15 fps)',
            selected:
                !voice.autoQuality &&
                voice.videoBitrate == 600000 &&
                voice.videoFps == 15,
            enabled: !voice.autoQuality,
            onTap: () => applyPreset(bitrate: 600000, fps: 15),
          ),
          _qualityRow(
            context,
            label: 'Balanced (1200 kbps, 24 fps)',
            selected:
                !voice.autoQuality &&
                voice.videoBitrate == 1200000 &&
                voice.videoFps == 24,
            enabled: !voice.autoQuality,
            onTap: () => applyPreset(bitrate: 1200000, fps: 24),
          ),
          _qualityRow(
            context,
            label: 'High (2000 kbps, 30 fps)',
            selected:
                !voice.autoQuality &&
                voice.videoBitrate == 2000000 &&
                voice.videoFps == 30,
            enabled: !voice.autoQuality,
            onTap: () => applyPreset(bitrate: 2000000, fps: 30),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _qualityRow(
    BuildContext context, {
    required String label,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color: enabled
                  ? (selected ? context.accent : context.textMuted)
                  : context.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? context.textPrimary
                      : context.textMuted.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
