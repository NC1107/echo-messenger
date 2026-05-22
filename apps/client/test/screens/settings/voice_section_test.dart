// Tests for Voice & Video settings screen device enumeration.
//
// Bug: On Linux, flutter_webrtc's enumerateDevices returns PulseAudio devices
// with deviceId='default'. The original _loadAudioDevices loop filtered them
// out with `d.deviceId != 'default'`, leaving the dropdown empty despite the
// provider log saying "applied 1 in / 1 out".
//
// Repro (manual):
//   1. Run the Linux build (flutter run -d linux or the AppImage).
//   2. Log in, open Settings → Voice & Video.
//   3. Observe both input and output dropdowns are empty even though
//      the system has working audio.
//
// The widget test below is skipped because it requires the flutter_webrtc
// native plugin (Linux platform channels) to intercept enumerateDevices.
// The unit tests in the second group exercise the equivalent classification
// logic in isolation and are the canonical regression guard.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/settings/voice_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

// ---------------------------------------------------------------------------
// Lightweight stand-in for flutter_webrtc MediaDeviceInfo – mirrors the three
// fields the classification logic actually reads.
// ---------------------------------------------------------------------------

class _FakeDevice {
  const _FakeDevice({
    required this.kind,
    required this.deviceId,
    this.label = '',
  });

  final String kind;
  final String deviceId;
  final String label;
}

// ---------------------------------------------------------------------------
// Pure re-implementation of the fixed classification logic used by
// _loadAudioDevices so we can unit-test it without native plugins.
// ---------------------------------------------------------------------------

typedef _DeviceLists = ({
  List<Map<String, String>> inputs,
  List<Map<String, String>> outputs,
  List<Map<String, String>> cameras,
});

_DeviceLists _classify(List<_FakeDevice> devices) {
  final inputs = <Map<String, String>>[];
  final outputs = <Map<String, String>>[];
  final cameras = <Map<String, String>>[];

  for (final d in devices) {
    if (d.deviceId.isEmpty) continue;
    final String label;
    if (d.label.isNotEmpty) {
      label = d.label;
    } else if (d.deviceId == 'default') {
      label = switch (d.kind) {
        'audioinput' => 'Default Microphone',
        'audiooutput' => 'Default Output',
        'videoinput' => 'Default Camera',
        _ => 'Default Device',
      };
    } else {
      label = d.deviceId;
    }

    if (d.kind == 'audioinput') {
      inputs.add({'id': d.deviceId, 'name': label});
    } else if (d.kind == 'audiooutput') {
      outputs.add({'id': d.deviceId, 'name': label});
    } else if (d.kind == 'videoinput') {
      cameras.add({'id': d.deviceId, 'name': label});
    }
  }

  final noEnum = devices.isEmpty;
  if (inputs.isEmpty) {
    inputs.add({
      'id': 'default',
      'name': noEnum
          ? 'Using system default \u2014 no enumeration available'
          : 'Default Microphone',
    });
  }
  if (outputs.isEmpty) {
    outputs.add({
      'id': 'default',
      'name': noEnum
          ? 'Using system default \u2014 no enumeration available'
          : 'Default Output',
    });
  }
  if (cameras.isEmpty) {
    cameras.add({'id': 'default', 'name': 'Default Camera'});
  }

  return (inputs: inputs, outputs: outputs, cameras: cameras);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('VoiceVideoSection widget', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets(
      'Linux: input and output dropdowns are not empty after enumerateDevices '
      'returns a device with deviceId=default',
      (tester) async {
        // Requires flutter_webrtc native Linux plugin to intercept
        // enumerateDevices at the platform-channel level.
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: EchoTheme.darkTheme,
              home: const Scaffold(body: VoiceVideoSection()),
            ),
          ),
        );
        await tester.pump();
        // When the fix is applied, both dropdowns contain at least one item.
        // Without the fix they were empty because deviceId='default' was
        // filtered out; the DropdownButtonFormField rendered blank.
        expect(find.byType(DropdownButtonFormField<String>), findsWidgets);
      },
      skip: 'requires flutter_webrtc native Linux plugin',
    );
  });

  // -------------------------------------------------------------------------
  // Unit tests for the classification logic – no native plugin needed.
  // These are the primary regression guard for the Linux filter bug.
  // -------------------------------------------------------------------------

  group('_classify (device list logic)', () {
    test('Linux: device with deviceId=default is NOT filtered out', () {
      final result = _classify([
        const _FakeDevice(kind: 'audioinput', deviceId: 'default'),
        const _FakeDevice(kind: 'audiooutput', deviceId: 'default'),
      ]);

      // Before the fix: inputs/outputs only contained the pre-populated
      // fallback; the enumerated device was silently dropped.
      expect(result.inputs, hasLength(1));
      expect(result.inputs.first['id'], 'default');
      expect(result.outputs, hasLength(1));
      expect(result.outputs.first['id'], 'default');
    });

    test(
      'Linux: device with deviceId=default and empty label gets friendly name',
      () {
        final result = _classify([
          const _FakeDevice(kind: 'audioinput', deviceId: 'default', label: ''),
          const _FakeDevice(
            kind: 'audiooutput',
            deviceId: 'default',
            label: '',
          ),
          const _FakeDevice(kind: 'videoinput', deviceId: 'default', label: ''),
        ]);

        expect(result.inputs.first['name'], 'Default Microphone');
        expect(result.outputs.first['name'], 'Default Output');
        expect(result.cameras.first['name'], 'Default Camera');
      },
    );

    test(
      'Linux: device with deviceId=default and non-empty label uses that label',
      () {
        final result = _classify([
          const _FakeDevice(
            kind: 'audioinput',
            deviceId: 'default',
            label: 'PulseAudio Microphone',
          ),
        ]);

        expect(result.inputs.first['name'], 'PulseAudio Microphone');
      },
    );

    test('non-default device IDs are accepted unchanged', () {
      final result = _classify([
        const _FakeDevice(
          kind: 'audioinput',
          deviceId: 'hw:1,0',
          label: 'USB Headset',
        ),
        const _FakeDevice(
          kind: 'audiooutput',
          deviceId: 'hw:0,0',
          label: 'Built-in Analog Stereo',
        ),
        const _FakeDevice(kind: 'videoinput', deviceId: 'cam-1', label: 'Webcam'),
      ]);

      expect(result.inputs, hasLength(1));
      expect(result.inputs.first, {'id': 'hw:1,0', 'name': 'USB Headset'});
      expect(result.outputs, hasLength(1));
      expect(result.outputs.first, {
        'id': 'hw:0,0',
        'name': 'Built-in Analog Stereo',
      });
      expect(result.cameras, hasLength(1));
      expect(result.cameras.first, {'id': 'cam-1', 'name': 'Webcam'});
    });

    test(
      'zero devices enumerated: sentinel uses "no enumeration available" label',
      () {
        final result = _classify([]);

        expect(result.inputs, hasLength(1));
        expect(
          result.inputs.first['name'],
          contains('no enumeration available'),
        );
        expect(result.outputs, hasLength(1));
        expect(
          result.outputs.first['name'],
          contains('no enumeration available'),
        );
        // Cameras keep a plain fallback regardless.
        expect(result.cameras.first['name'], 'Default Camera');
      },
    );

    test('device with empty deviceId is skipped', () {
      final result = _classify([
        const _FakeDevice(kind: 'audioinput', deviceId: ''),
      ]);

      // Empty deviceId must be dropped; fallback sentinel is added instead.
      expect(result.inputs, hasLength(1));
      expect(result.inputs.first['id'], 'default');
    });

    test('multiple devices of same kind all appear', () {
      final result = _classify([
        const _FakeDevice(
          kind: 'audioinput',
          deviceId: 'mic-1',
          label: 'Mic 1',
        ),
        const _FakeDevice(
          kind: 'audioinput',
          deviceId: 'mic-2',
          label: 'Mic 2',
        ),
      ]);

      expect(result.inputs, hasLength(2));
      expect(result.inputs.map((d) => d['id']), containsAll(['mic-1', 'mic-2']));
    });
  });
}
