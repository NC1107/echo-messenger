import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/voice_settings_provider.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('VoiceSettingsState', () {
    test('default state has sensible defaults', () {
      const state = VoiceSettingsState();
      expect(state.inputDeviceId, 'default');
      expect(state.outputDeviceId, 'default');
      expect(state.cameraDeviceId, 'default');
      expect(state.inputGain, 1.0);
      expect(state.outputVolume, 1.0);
      expect(state.pushToTalkEnabled, isFalse);
      expect(state.pushToTalkKeyId, '32');
      expect(state.pushToTalkKeyLabel, 'Space');
      expect(state.selfMuted, isFalse);
      expect(state.selfDeafened, isFalse);
      expect(state.noiseSuppression, isTrue);
      expect(state.echoCancellation, isTrue);
      expect(state.autoGainControl, isTrue);
    });

    test('copyWith preserves unchanged fields', () {
      const state = VoiceSettingsState(
        inputDeviceId: 'mic-1',
        selfMuted: true,
        noiseSuppression: false,
      );
      final copied = state.copyWith(outputVolume: 0.5);
      expect(copied.inputDeviceId, 'mic-1');
      expect(copied.selfMuted, isTrue);
      expect(copied.noiseSuppression, isFalse);
      expect(copied.outputVolume, 0.5);
    });

    test('copyWith can update each field', () {
      const state = VoiceSettingsState();
      expect(state.copyWith(inputDeviceId: 'mic-2').inputDeviceId, 'mic-2');
      expect(state.copyWith(outputDeviceId: 'spk-2').outputDeviceId, 'spk-2');
      expect(state.copyWith(cameraDeviceId: 'cam-2').cameraDeviceId, 'cam-2');
      expect(state.copyWith(inputGain: 0.8).inputGain, 0.8);
      expect(state.copyWith(outputVolume: 0.5).outputVolume, 0.5);
      expect(state.copyWith(pushToTalkEnabled: true).pushToTalkEnabled, isTrue);
      expect(state.copyWith(pushToTalkKeyId: '65').pushToTalkKeyId, '65');
      expect(state.copyWith(pushToTalkKeyLabel: 'A').pushToTalkKeyLabel, 'A');
      expect(state.copyWith(selfMuted: true).selfMuted, isTrue);
      expect(state.copyWith(selfDeafened: true).selfDeafened, isTrue);
      expect(state.copyWith(noiseSuppression: false).noiseSuppression, isFalse);
      expect(state.copyWith(echoCancellation: false).echoCancellation, isFalse);
      expect(state.copyWith(autoGainControl: false).autoGainControl, isFalse);
    });
  });

  group('VoiceSettings notifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('loads defaults from empty SharedPreferences', () async {
      final container = _container();
      // Trigger build() then wait for async _load.
      container.read(voiceSettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(voiceSettingsProvider);
      expect(state.inputDeviceId, 'default');
      expect(state.outputVolume, 1.0);
      expect(state.noiseSuppression, isTrue);
    });

    test('loads persisted values', () async {
      SharedPreferences.setMockInitialValues({
        'voice_input_device_id': 'mic-custom',
        'voice_output_volume': 0.7,
        'voice_self_muted': true,
        'voice_noise_suppression': false,
      });

      final container = _container();
      container.read(voiceSettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(voiceSettingsProvider);
      expect(state.inputDeviceId, 'mic-custom');
      expect(state.outputVolume, 0.7);
      expect(state.selfMuted, isTrue);
      expect(state.noiseSuppression, isFalse);
    });

    test('setInputDevice updates state and persists', () async {
      final container = _container();
      final notifier = container.read(voiceSettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setInputDevice('mic-new');
      expect(container.read(voiceSettingsProvider).inputDeviceId, 'mic-new');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('voice_input_device_id'), 'mic-new');
    });

    test('setOutputVolume updates state and persists', () async {
      final container = _container();
      final notifier = container.read(voiceSettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setOutputVolume(0.3);
      expect(container.read(voiceSettingsProvider).outputVolume, 0.3);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('voice_output_volume'), 0.3);
    });

    test('setSelfMuted updates state and persists', () async {
      final container = _container();
      final notifier = container.read(voiceSettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setSelfMuted(true);
      expect(container.read(voiceSettingsProvider).selfMuted, isTrue);
    });

    test('setSelfDeafened updates state and persists', () async {
      final container = _container();
      final notifier = container.read(voiceSettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setSelfDeafened(true);
      expect(container.read(voiceSettingsProvider).selfDeafened, isTrue);
    });

    test('setNoiseSuppression updates state and persists', () async {
      final container = _container();
      final notifier = container.read(voiceSettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setNoiseSuppression(false);
      expect(container.read(voiceSettingsProvider).noiseSuppression, isFalse);
    });

    test('setEchoCancellation updates state and persists', () async {
      final container = _container();
      final notifier = container.read(voiceSettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setEchoCancellation(false);
      expect(container.read(voiceSettingsProvider).echoCancellation, isFalse);
    });

    test('setPushToTalkKey updates both id and label', () async {
      final container = _container();
      final notifier = container.read(voiceSettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setPushToTalkKey(keyId: '65', keyLabel: 'A');
      final state = container.read(voiceSettingsProvider);
      expect(state.pushToTalkKeyId, '65');
      expect(state.pushToTalkKeyLabel, 'A');
    });
  });
}
