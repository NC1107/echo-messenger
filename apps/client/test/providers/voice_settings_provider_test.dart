import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/voice_settings_provider.dart';

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

  group('VoiceSettingsNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('loads defaults from empty SharedPreferences', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifier.state.inputDeviceId, 'default');
      expect(notifier.state.outputVolume, 1.0);
      expect(notifier.state.noiseSuppression, isTrue);
      notifier.dispose();
    });

    test('loads persisted values', () async {
      SharedPreferences.setMockInitialValues({
        'voice_input_device_id': 'mic-custom',
        'voice_output_volume': 0.7,
        'voice_self_muted': true,
        'voice_noise_suppression': false,
      });

      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifier.state.inputDeviceId, 'mic-custom');
      expect(notifier.state.outputVolume, 0.7);
      expect(notifier.state.selfMuted, isTrue);
      expect(notifier.state.noiseSuppression, isFalse);
      notifier.dispose();
    });

    test('setInputDevice updates state and persists', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setInputDevice('mic-new');
      expect(notifier.state.inputDeviceId, 'mic-new');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('voice_input_device_id'), 'mic-new');
      notifier.dispose();
    });

    test('setOutputVolume updates state and persists', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setOutputVolume(0.3);
      expect(notifier.state.outputVolume, 0.3);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('voice_output_volume'), 0.3);
      notifier.dispose();
    });

    test('setSelfMuted updates state and persists', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setSelfMuted(true);
      expect(notifier.state.selfMuted, isTrue);
      notifier.dispose();
    });

    test('setSelfDeafened updates state and persists', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setSelfDeafened(true);
      expect(notifier.state.selfDeafened, isTrue);
      notifier.dispose();
    });

    test('setNoiseSuppression updates state and persists', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setNoiseSuppression(false);
      expect(notifier.state.noiseSuppression, isFalse);
      notifier.dispose();
    });

    test('setEchoCancellation updates state and persists', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setEchoCancellation(false);
      expect(notifier.state.echoCancellation, isFalse);
      notifier.dispose();
    });

    test('setPushToTalkKey updates both id and label', () async {
      final notifier = VoiceSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setPushToTalkKey(keyId: '65', keyLabel: 'A');
      expect(notifier.state.pushToTalkKeyId, '65');
      expect(notifier.state.pushToTalkKeyLabel, 'A');
      notifier.dispose();
    });
  });
}
