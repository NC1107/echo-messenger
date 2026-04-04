import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../../providers/voice_settings_provider.dart';
import '../../theme/echo_theme.dart';

class AudioSection extends ConsumerStatefulWidget {
  const AudioSection({super.key});

  @override
  ConsumerState<AudioSection> createState() => _AudioSectionState();
}

class _AudioSectionState extends ConsumerState<AudioSection> {
  List<Map<String, String>> _audioInputDevices = [
    {'id': 'default', 'name': 'Default Microphone'},
  ];
  List<Map<String, String>> _audioOutputDevices = [
    {'id': 'default', 'name': 'Default Output'},
  ];
  bool _devicesLoaded = false;

  String _friendlyKeyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      return 'Ctrl';
    }
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      return 'Shift';
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      return 'Alt';
    }
    if (key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      return 'Meta';
    }

    final label = key.keyLabel.trim();
    if (label.isNotEmpty) return label.toUpperCase();
    return (key.debugName ?? 'Unknown').replaceAll(' ', '');
  }

  Future<void> _capturePushToTalkKey(VoiceSettingsNotifier notifier) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        String captured = 'Press any key...';
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            backgroundColor: context.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: context.border),
            ),
            title: Text(
              'Set Push-to-Talk Key',
              style: TextStyle(color: context.textPrimary, fontSize: 17),
            ),
            content: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent) {
                  final label = _friendlyKeyLabel(event.logicalKey);
                  setDialogState(() {
                    captured = label;
                  });
                  Navigator.pop(dialogContext, {
                    'id': event.logicalKey.keyId.toString(),
                    'label': label,
                  });
                }
                return KeyEventResult.handled;
              },
              child: Container(
                width: 340,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: context.mainBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.border),
                ),
                child: Text(
                  captured,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );

    if (result == null) return;
    final keyId = result['id'];
    final keyLabel = result['label'];
    if (keyId == null || keyLabel == null) return;
    await notifier.setPushToTalkKey(keyId: keyId, keyLabel: keyLabel);
  }

  Future<void> _loadAudioDevices() async {
    if (_devicesLoaded) return;
    _devicesLoaded = true;
    try {
      final devices = await webrtc.navigator.mediaDevices.enumerateDevices();
      final inputs = <Map<String, String>>[
        {'id': 'default', 'name': 'Default Microphone'},
      ];
      final outputs = <Map<String, String>>[
        {'id': 'default', 'name': 'Default Output'},
      ];
      for (final d in devices) {
        final label = d.label.isNotEmpty ? d.label : d.deviceId;
        if (d.kind == 'audioinput' && d.deviceId != 'default') {
          inputs.add({'id': d.deviceId, 'name': label});
        } else if (d.kind == 'audiooutput' && d.deviceId != 'default') {
          outputs.add({'id': d.deviceId, 'name': label});
        }
      }
      if (mounted) {
        setState(() {
          _audioInputDevices = inputs;
          _audioOutputDevices = outputs;
        });
      }
    } catch (_) {
      // Enumeration not available on this platform
    }
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(voiceSettingsProvider);
    final notifier = ref.read(voiceSettingsProvider.notifier);

    // Load real devices on first build
    _loadAudioDevices();

    final inputDevices = _audioInputDevices;
    final outputDevices = _audioOutputDevices;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Voice & Audio',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Configure voice device preferences and push-to-talk behavior.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          initialValue: inputDevices.any((d) => d['id'] == voice.inputDeviceId)
              ? voice.inputDeviceId
              : 'default',
          decoration: const InputDecoration(labelText: 'Input Device'),
          items: inputDevices
              .map(
                (device) => DropdownMenuItem(
                  value: device['id'],
                  child: Text(device['name']!),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) notifier.setInputDevice(value);
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue:
              outputDevices.any((d) => d['id'] == voice.outputDeviceId)
              ? voice.outputDeviceId
              : 'default',
          decoration: const InputDecoration(labelText: 'Output Device'),
          items: outputDevices
              .map(
                (device) => DropdownMenuItem(
                  value: device['id'],
                  child: Text(device['name']!),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) notifier.setOutputDevice(value);
          },
        ),
        const SizedBox(height: 16),
        Text(
          'Input Sensitivity',
          style: TextStyle(color: context.textPrimary, fontSize: 13),
        ),
        Slider(
          value: voice.inputGain,
          min: 0,
          max: 2,
          divisions: 20,
          label: voice.inputGain.toStringAsFixed(1),
          onChanged: notifier.setInputGain,
        ),
        const SizedBox(height: 8),
        Text(
          'Output Volume',
          style: TextStyle(color: context.textPrimary, fontSize: 13),
        ),
        Slider(
          value: voice.outputVolume,
          min: 0,
          max: 1,
          divisions: 20,
          label: (voice.outputVolume * 100).round().toString(),
          onChanged: notifier.setOutputVolume,
        ),
        const SizedBox(height: 10),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Push-to-Talk',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'When enabled, your mic transmits only while push-to-talk is active.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: voice.pushToTalkEnabled,
          onChanged: notifier.setPushToTalkEnabled,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Push-to-Talk Key',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            voice.pushToTalkKeyLabel,
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: OutlinedButton(
            onPressed: () => _capturePushToTalkKey(notifier),
            child: const Text('Set Key'),
          ),
        ),
      ],
    );
  }
}
