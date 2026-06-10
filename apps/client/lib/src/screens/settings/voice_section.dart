import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../../providers/voice_settings_provider.dart';
import '../../services/debug_log_service.dart';
import '../../services/sound_service.dart';
import '../../theme/echo_theme.dart';
import '../../utils/audio_level_analyzer.dart';
import '../../widgets/settings_panel_scaffold.dart';

/// Voice & Video settings.
///
/// Originally a subpage of [NotificationSection] (#audit-batch-f). Promoted
/// to its own top-level Settings section so users hunting for "input device"
/// or "push-to-talk" don't have to dig under Notifications.
class VoiceVideoSection extends ConsumerStatefulWidget {
  const VoiceVideoSection({super.key});

  @override
  ConsumerState<VoiceVideoSection> createState() => _VoiceVideoSectionState();
}

// Friendly fallback names for unlabeled "default" devices. Hoisted because
// each is used 3+ times (S1192).
const _kDefaultMic = 'Default Microphone';
const _kDefaultOutput = 'Default Output';
const _kDefaultCamera = 'Default Camera';
// — = em dash. (Used twice — kept as a const for the shared helper below.)
const _kNoEnumDeviceName = 'Using system default — no enumeration available';

class _VoiceVideoSectionState extends ConsumerState<VoiceVideoSection> {
  List<Map<String, String>> _audioInputDevices = [
    {'id': 'default', 'name': _kDefaultMic},
  ];
  List<Map<String, String>> _audioOutputDevices = [
    {'id': 'default', 'name': _kDefaultOutput},
  ];
  List<Map<String, String>> _videoInputDevices = [
    {'id': 'default', 'name': _kDefaultCamera},
  ];
  bool _devicesLoaded = false;

  /// Set to true when [_loadAudioDevices] catches an exception so the UI can
  /// offer a Retry button rather than silently showing stale defaults.
  bool _deviceEnumerationFailed = false;

  // Mic test state
  bool _isMicTesting = false;
  double _micLevel = 0.0;
  Timer? _micTestTimer;
  webrtc.MediaStream? _micTestStream;
  AudioLevelAnalyzer? _audioLevelAnalyzer;

  // Sound test state
  bool _isPlayingTestSound = false;

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

  @override
  void initState() {
    super.initState();
    // Kick off device enumeration exactly once, safely outside build.
    // unawaited is intentional: the async result is handled inside
    // _loadAudioDevices via setState / _deviceEnumerationFailed.
    unawaited(_loadAudioDevices());
  }

  @override
  void dispose() {
    // Cancel the timer and release native resources without calling setState —
    // setState during dispose triggers a _lifecycleState assertion because the
    // element is already being torn down.
    _micTestTimer?.cancel();
    _micTestTimer = null;
    _audioLevelAnalyzer?.dispose();
    _audioLevelAnalyzer = null;
    final stream = _micTestStream;
    _micTestStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      stream.dispose();
    }
    super.dispose();
  }

  Future<void> _playTestSound() async {
    if (_isPlayingTestSound) return;
    setState(() => _isPlayingTestSound = true);

    try {
      await SoundService().playMessageReceived();
      // Brief delay so the button shows "Playing..." while the sound plays.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    } catch (_) {
      // Audio not available
    }
    if (mounted) setState(() => _isPlayingTestSound = false);
  }

  Future<void> _startMicTest() async {
    if (_isMicTesting) return;
    setState(() {
      _isMicTesting = true;
      _micLevel = 0.0;
    });

    try {
      _micTestStream = await webrtc.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

      // Create an audio level analyzer from the real mic stream
      _audioLevelAnalyzer = AudioLevelAnalyzer.fromStream(_micTestStream!);

      // Poll the real mic level every 50ms for responsive metering.
      _micTestTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (!mounted) {
          _stopMicTest();
          return;
        }
        final level = _audioLevelAnalyzer?.getLevel() ?? 0.0;
        setState(() {
          _micLevel = level;
        });
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isMicTesting = false;
          _micLevel = 0.0;
        });
      }
    }
  }

  void _stopMicTest() {
    _micTestTimer?.cancel();
    _micTestTimer = null;

    _audioLevelAnalyzer?.dispose();
    _audioLevelAnalyzer = null;

    final stream = _micTestStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      stream.dispose();
      _micTestStream = null;
    }

    if (mounted) {
      setState(() {
        _isMicTesting = false;
        _micLevel = 0.0;
      });
    }
  }

  Future<void> _capturePushToTalkKey(VoiceSettings notifier) async {
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

    // TestFlight 500 crashed iOS 26.5 with isEqualToString: in flutter_webrtc; breadcrumbs for next repro.
    DebugLogService.instance.log(
      LogLevel.info,
      'VoiceSettings',
      '_loadAudioDevices: start (platform=$defaultTargetPlatform)',
    );
    try {
      final devices = await webrtc.navigator.mediaDevices.enumerateDevices();
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceSettings',
        '_loadAudioDevices: enumerateDevices returned ${devices.length} '
            'device(s)',
      );
      final picks = _classifyDevices(devices);
      if (mounted) {
        setState(() {
          _audioInputDevices = picks.inputs;
          _audioOutputDevices = picks.outputs;
          _videoInputDevices = picks.cameras;
        });
      }
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceSettings',
        '_loadAudioDevices: applied ${picks.inputs.length} in / '
            '${picks.outputs.length} out / ${picks.cameras.length} cam',
      );
    } catch (e, st) {
      // Persist the error: bare `catch (_)` swallowed the type-confusion preceding the native crash.
      DebugLogService.instance.log(
        LogLevel.error,
        'VoiceSettings',
        '_loadAudioDevices threw: $e\n$st',
      );
      // Mark failure so the UI can show a note + Retry button instead of
      // silently displaying stale defaults. _devicesLoaded is already true
      // (set above the try), so a rebuild will never retry automatically.
      if (mounted) {
        setState(() {
          _deviceEnumerationFailed = true;
        });
      }
    }
  }

  /// Friendly label for one enumerated device: its real label, a per-kind
  /// "Default …" name for an unlabeled `default` device (Linux/PulseAudio
  /// exposes these), else the raw id.
  String _deviceLabel(webrtc.MediaDeviceInfo d) {
    if (d.label.isNotEmpty) return d.label;
    if (d.deviceId == 'default') {
      return switch (d.kind) {
        'audioinput' => _kDefaultMic,
        'audiooutput' => _kDefaultOutput,
        'videoinput' => _kDefaultCamera,
        _ => 'Default Device',
      };
    }
    return d.deviceId;
  }

  /// Split enumerated devices into input/output/camera dropdown entries,
  /// adding a sentinel entry per kind when none were found so the dropdowns
  /// are never blank. Extracted from [_loadAudioDevices] to keep its cognitive
  /// complexity in budget (S3776).
  ({
    List<Map<String, String>> inputs,
    List<Map<String, String>> outputs,
    List<Map<String, String>> cameras,
  })
  _classifyDevices(List<webrtc.MediaDeviceInfo> devices) {
    final inputs = <Map<String, String>>[];
    final outputs = <Map<String, String>>[];
    final cameras = <Map<String, String>>[];
    for (final d in devices) {
      if (d.deviceId.isEmpty) continue;
      final entry = {'id': d.deviceId, 'name': _deviceLabel(d)};
      switch (d.kind) {
        case 'audioinput':
          inputs.add(entry);
        case 'audiooutput':
          outputs.add(entry);
        case 'videoinput':
          cameras.add(entry);
      }
    }
    // Sentinels when empty; distinguish "no enumeration" from "no device of
    // this kind".
    final noEnum = devices.isEmpty;
    if (inputs.isEmpty) {
      inputs.add({
        'id': 'default',
        'name': noEnum ? _kNoEnumDeviceName : _kDefaultMic,
      });
    }
    if (outputs.isEmpty) {
      outputs.add({
        'id': 'default',
        'name': noEnum ? _kNoEnumDeviceName : _kDefaultOutput,
      });
    }
    if (cameras.isEmpty) {
      cameras.add({'id': 'default', 'name': _kDefaultCamera});
    }
    return (inputs: inputs, outputs: outputs, cameras: cameras);
  }

  Color _micLevelColor() {
    if (_micLevel > 0.7) return EchoTheme.danger;
    if (_micLevel > 0.4) return EchoTheme.warning;
    return EchoTheme.online;
  }

  /// Reusable device picker dropdown.
  Widget _buildDevicePicker({
    required String label,
    required List<Map<String, String>> devices,
    required String currentId,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: devices.any((d) => d['id'] == currentId)
          ? currentId
          : 'default',
      decoration: InputDecoration(labelText: label),
      items: devices
          .map(
            (device) => DropdownMenuItem(
              value: device['id'],
              child: Text(device['name']!),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(voiceSettingsProvider);
    final notifier = ref.read(voiceSettingsProvider.notifier);

    final inputDevices = _audioInputDevices;
    final outputDevices = _audioOutputDevices;
    final cameraDevices = _videoInputDevices;

    return SettingsPanelScaffold(
      children: [
        Text(
          'Voice & Video',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
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
        _buildDevicePicker(
          label: 'Input Device',
          devices: inputDevices,
          currentId: voice.inputDeviceId,
          onChanged: notifier.setInputDevice,
        ),
        const SizedBox(height: 12),
        _buildDevicePicker(
          label: 'Output Device',
          devices: outputDevices,
          currentId: voice.outputDeviceId,
          onChanged: notifier.setOutputDevice,
        ),
        const SizedBox(height: 12),
        _buildDevicePicker(
          label: 'Camera',
          devices: cameraDevices,
          currentId: voice.cameraDeviceId,
          onChanged: notifier.setCameraDevice,
        ),
        if (_deviceEnumerationFailed) ...[
          const SizedBox(height: 8),
          _DeviceEnumerationErrorNote(
            onRetry: () {
              setState(() {
                _devicesLoaded = false;
                _deviceEnumerationFailed = false;
              });
              unawaited(_loadAudioDevices());
            },
          ),
        ],
        const SizedBox(height: 12),
        _CameraPreview(deviceId: voice.cameraDeviceId),
        const SizedBox(height: 16),
        Text(
          'Microphone Gain',
          style: TextStyle(color: context.textPrimary, fontSize: 13),
        ),
        Semantics(
          label: 'Microphone gain',
          slider: true,
          value: '${(voice.inputGain * 100).toInt()}%',
          child: Slider(
            value: voice.inputGain,
            min: 0,
            max: 2,
            divisions: 20,
            label: voice.inputGain.toStringAsFixed(1),
            onChanged: notifier.setInputGain,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Output Volume',
          style: TextStyle(color: context.textPrimary, fontSize: 13),
        ),
        Semantics(
          label: 'Output volume',
          slider: true,
          value: '${(voice.outputVolume * 100).toInt()}%',
          child: Slider(
            value: voice.outputVolume,
            min: 0,
            max: 1,
            divisions: 20,
            label: (voice.outputVolume * 100).round().toString(),
            onChanged: notifier.setOutputVolume,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _isPlayingTestSound ? null : _playTestSound,
              icon: Icon(
                _isPlayingTestSound ? Icons.volume_up : Icons.play_arrow,
                size: 18,
              ),
              label: Text(_isPlayingTestSound ? 'Playing...' : 'Test Sound'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _isMicTesting ? _stopMicTest : _startMicTest,
              icon: Icon(_isMicTesting ? Icons.stop : Icons.mic, size: 18),
              label: Text(_isMicTesting ? 'Stop' : 'Test Microphone'),
            ),
          ],
        ),
        if (_isMicTesting) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.mic, size: 16, color: context.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _micLevel,
                    minHeight: 8,
                    backgroundColor: context.surface,
                    valueColor: AlwaysStoppedAnimation<Color>(_micLevelColor()),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(_micLevel * 100).round()}%',
                style: TextStyle(color: context.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ],
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
        AnimatedOpacity(
          opacity: voice.pushToTalkEnabled ? 1.0 : 0.4,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !voice.pushToTalkEnabled,
            child: ListTile(
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
          ),
        ),
        const SizedBox(height: 16),
        Divider(color: context.border),
        const SizedBox(height: 16),
        Text(
          'Audio Processing',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'These settings apply the next time you join a voice channel.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Noise Suppression',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Reduce background noise like fans, typing, and ambient sounds.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: voice.noiseSuppression,
          onChanged: (v) => notifier.setNoiseSuppression(v),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Echo Cancellation',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Prevent your speakers from feeding back into your microphone.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: voice.echoCancellation,
          onChanged: (v) => notifier.setEchoCancellation(v),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Auto Gain Control',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Automatically adjust microphone volume for consistent levels.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: voice.autoGainControl,
          onChanged: (v) => notifier.setAutoGainControl(v),
        ),
        const SizedBox(height: 16),
        Divider(color: context.border),
        const SizedBox(height: 16),
        Text(
          'Channel Behaviour',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Confirm before joining voice channel',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Show a confirmation dialog before connecting to a voice channel.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: voice.confirmBeforeJoinVoice,
          onChanged: notifier.setConfirmBeforeJoinVoice,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Device enumeration error note
// ---------------------------------------------------------------------------

/// Shown below the device pickers when [_VoiceVideoSectionState._loadAudioDevices]
/// throws (e.g. WebRTC not ready, permission not granted, unsupported platform).
/// Keeps the defaults visible so the rest of the settings screen remains usable.
class _DeviceEnumerationErrorNote extends StatelessWidget {
  const _DeviceEnumerationErrorNote({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.warning_amber_rounded, size: 14, color: context.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            "Couldn't list audio/video devices — showing defaults.",
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Retry', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Live camera preview
// ---------------------------------------------------------------------------

/// Renders a live preview of the selected camera so users can confirm framing
/// and focus before joining a call. Tears down + re-opens the stream when the
/// selected [deviceId] changes, and stops tracks on dispose.
///
/// Supported on Android, iOS, macOS and Web (any platform where
/// `flutter_webrtc`'s `getUserMedia` is reliable). Linux/Windows desktop fall
/// back to a "preview not supported" placeholder.
class _CameraPreview extends StatefulWidget {
  /// The voice-settings camera device id. Empty string means "default".
  final String deviceId;

  const _CameraPreview({required this.deviceId});

  @override
  State<_CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<_CameraPreview> {
  final webrtc.RTCVideoRenderer _renderer = webrtc.RTCVideoRenderer();
  webrtc.MediaStream? _stream;
  bool _rendererInitialized = false;
  String? _error;
  bool _permissionDenied = false;
  // Monotonic generation counter — every _restart()/_startStream() entry
  // increments this and captures the new value locally. Any in-flight call
  // whose captured value no longer matches must cancel cleanly without
  // mutating shared state, preventing device-change races (#404).
  int _generation = 0;

  bool get _platformSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  void initState() {
    super.initState();
    if (_platformSupported) {
      _initRenderer();
    }
  }

  @override
  void didUpdateWidget(covariant _CameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId && _platformSupported) {
      _restart();
    }
  }

  Future<void> _initRenderer() async {
    final int gen = ++_generation;
    await _renderer.initialize();
    if (!mounted || gen != _generation) return;
    setState(() => _rendererInitialized = true);
    await _startStream();
  }

  Future<void> _restart() async {
    // Skip if renderer not yet initialised — device-id change racing init() throws StateError.
    if (!_rendererInitialized) return;
    await _stopStream();
    await _startStream();
  }

  Future<void> _startStream() async {
    final int gen = ++_generation;
    if (mounted) {
      setState(() {
        _error = null;
        _permissionDenied = false;
      });
    }
    try {
      final constraints = <String, dynamic>{
        'audio': false,
        'video': widget.deviceId.isEmpty
            ? true
            : {
                'deviceId': {'exact': widget.deviceId},
              },
      };
      final stream = await webrtc.navigator.mediaDevices.getUserMedia(
        constraints,
      );
      // Stale call (newer _startStream/_restart superseded us) or widget
      // unmounted: tear down the just-acquired stream and bail out without
      // touching shared state.
      if (!mounted || gen != _generation) {
        for (final t in stream.getTracks()) {
          t.stop();
        }
        await stream.dispose();
        return;
      }
      _stream = stream;
      _renderer.srcObject = stream;
      setState(() {});
    } catch (e) {
      if (!mounted || gen != _generation) return;
      final msg = e.toString().toLowerCase();
      setState(() {
        _permissionDenied =
            msg.contains('permission') || msg.contains('notallowed');
        _error = _permissionDenied
            ? 'Camera access blocked.'
            : 'Could not start camera preview.';
      });
    }
  }

  Future<void> _stopStream() async {
    final stream = _stream;
    _stream = null;
    _renderer.srcObject = null;
    if (stream != null) {
      for (final t in stream.getTracks()) {
        t.stop();
      }
      await stream.dispose();
    }
  }

  @override
  void dispose() {
    // Sync dispose: async stop() left the Android camera live until GC, with the OS indicator on.
    _generation++;
    final stream = _stream;
    final rendererInitialized = _rendererInitialized;
    _stream = null;
    _rendererInitialized = false;
    // RTCVideoRenderer throws on srcObject=null without init; skip the clear when uninitialised.
    if (rendererInitialized) {
      _renderer.srcObject = null;
    }
    if (stream != null) {
      for (final t in stream.getTracks()) {
        t.stop();
      }
      // Unawaited: dispose() is sync. Track.stop() above already released
      // the hardware; this just cleans up plugin-side handles.
      // ignore: unawaited_futures
      stream.dispose();
    }
    if (rendererInitialized) {
      // ignore: unawaited_futures
      _renderer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_platformSupported) {
      return _buildPlaceholder(
        context,
        icon: Icons.videocam_off_outlined,
        message: 'Preview not supported on this platform.',
      );
    }
    if (_error != null) {
      return _buildPlaceholder(
        context,
        icon: _permissionDenied ? Icons.lock_outline : Icons.error_outline,
        message: _error!,
        action: _permissionDenied
            ? TextButton(
                onPressed: _startStream,
                child: const Text('Grant camera access'),
              )
            : null,
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.black,
              child: _rendererInitialized && _stream != null
                  ? webrtc.RTCVideoView(
                      _renderer,
                      objectFit: webrtc
                          .RTCVideoViewObjectFit
                          .RTCVideoViewObjectFitCover,
                      mirror: true,
                    )
                  : const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(
    BuildContext context, {
    required IconData icon,
    required String message,
    Widget? action,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.border),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: context.textMuted, size: 28),
                const SizedBox(height: 8),
                Text(
                  message,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                if (action != null) ...[const SizedBox(height: 8), action],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
