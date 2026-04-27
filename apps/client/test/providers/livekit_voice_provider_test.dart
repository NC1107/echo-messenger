// Regression test for livekit_client v2.7 API change.
//
// In livekit_client <2.7, AudioPublishOptions accepted `audioBitrate` with an
// `AudioPreset` value.  In v2.7 both were removed; the replacement is the
// `encoding` parameter that takes an `AudioEncoding` value.
//
// The bug caused `flutter analyze` to fail with:
//   error • The named parameter 'audioBitrate' isn't defined
//   error • Undefined name 'AudioPreset'
// on lib/src/providers/livekit_voice_provider.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';

import 'package:echo_app/src/providers/livekit_voice_provider.dart';

void main() {
  group('LiveKitVoiceState', () {
    test('initial state matches expected defaults', () {
      const state = LiveKitVoiceState();
      expect(state.isActive, isFalse);
      expect(state.isJoining, isFalse);
      expect(state.isCaptureEnabled, isTrue);
      expect(state.isDeafened, isFalse);
      expect(state.isVideoEnabled, isFalse);
      expect(state.videoBitrate, 1500000);
      expect(state.videoFps, 30);
      expect(state.autoQuality, isTrue);
      expect(state.conversationId, isNull);
      expect(state.channelId, isNull);
      expect(state.peerAudioLevels, isEmpty);
      expect(state.localAudioLevel, 0.0);
      expect(state.peerCount, 0);
      expect(state.peerConnectionStates, isEmpty);
      expect(state.peerLatencies, isEmpty);
      expect(state.error, isNull);
    });

    test('copyWith updates individual fields', () {
      const state = LiveKitVoiceState();
      final updated = state.copyWith(
        isActive: true,
        isJoining: true,
        peerCount: 3,
        error: 'disconnected',
      );
      expect(updated.isActive, isTrue);
      expect(updated.isJoining, isTrue);
      expect(updated.peerCount, 3);
      expect(updated.error, 'disconnected');
      // unchanged fields are preserved
      expect(updated.videoBitrate, 1500000);
      expect(updated.isCaptureEnabled, isTrue);
    });

    test('LiveKitVoiceState.empty is equivalent to default constructor', () {
      expect(LiveKitVoiceState.empty.isActive, isFalse);
      expect(LiveKitVoiceState.empty.error, isNull);
    });
  });

  // Regression: livekit_client v2.7 removed AudioPreset + audioBitrate.
  // This test verifies the replacement API (AudioEncoding / encoding) compiles
  // and produces the expected constant — if someone reverts the fix the
  // analysis step will surface "undefined_named_parameter" and
  // "undefined_identifier" errors for AudioPreset.
  group('livekit_client v2.7 AudioPublishOptions API', () {
    test('AudioPublishOptions accepts encoding with AudioEncoding.presetMusic',
        () {
      const opts = AudioPublishOptions(
        encoding: AudioEncoding.presetMusic,
        dtx: true,
      );
      expect(opts.dtx, isTrue);
      expect(opts.encoding, AudioEncoding.presetMusic);
    });
  });
}
