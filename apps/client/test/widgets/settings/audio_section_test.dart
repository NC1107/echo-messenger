import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/voice_settings_provider.dart';

/// AudioSection uses platform-specific media device APIs that are unavailable
/// in widget tests. Test the underlying state model instead.
void main() {
  group('VoiceSettingsState (audio section coverage)', () {
    test('default audio processing settings are enabled', () {
      const state = VoiceSettingsState();
      expect(state.noiseSuppression, isTrue);
      expect(state.echoCancellation, isTrue);
      expect(state.autoGainControl, isTrue);
    });

    test('default device IDs are "default"', () {
      const state = VoiceSettingsState();
      expect(state.inputDeviceId, 'default');
      expect(state.outputDeviceId, 'default');
      expect(state.cameraDeviceId, 'default');
    });

    test('default volumes are 1.0', () {
      const state = VoiceSettingsState();
      expect(state.inputGain, 1.0);
      expect(state.outputVolume, 1.0);
    });

    test('push-to-talk defaults to disabled with Space key', () {
      const state = VoiceSettingsState();
      expect(state.pushToTalkEnabled, isFalse);
      expect(state.pushToTalkKeyId, '32');
      expect(state.pushToTalkKeyLabel, 'Space');
    });

    test('self-mute and self-deafen default to false', () {
      const state = VoiceSettingsState();
      expect(state.selfMuted, isFalse);
      expect(state.selfDeafened, isFalse);
    });
  });
}
