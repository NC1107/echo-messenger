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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';

import 'package:echo_app/src/providers/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/livekit_voice/rtc_stats_poll.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      expect(state.audioBitrateBps, 0);
      expect(state.rttMs, 0);
    });

    test('copyWith updates rtc stats fields (#937)', () {
      const state = LiveKitVoiceState();
      final updated = state.copyWith(audioBitrateBps: 32000, rttMs: 47.5);
      expect(updated.audioBitrateBps, 32000);
      expect(updated.rttMs, 47.5);
      // unchanged fields preserved
      expect(updated.isActive, isFalse);
      expect(updated.videoBitrate, 1500000);
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
  group('RtcStatsSample (#937)', () {
    test('empty sentinel is zeroed', () {
      expect(RtcStatsSample.empty.audioBitrateBps, 0);
      expect(RtcStatsSample.empty.rttMs, 0);
    });

    test('equality compares both fields', () {
      const a = RtcStatsSample(audioBitrateBps: 32000, rttMs: 50.0);
      const b = RtcStatsSample(audioBitrateBps: 32000, rttMs: 50.0);
      const c = RtcStatsSample(audioBitrateBps: 32000, rttMs: 51.0);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('livekit_client v2.7 AudioPublishOptions API', () {
    test(
      'AudioPublishOptions accepts encoding with AudioEncoding.presetMusic',
      () {
        const opts = AudioPublishOptions(
          encoding: AudioEncoding.presetMusic,
          dtx: true,
        );
        expect(opts.dtx, isTrue);
        expect(opts.encoding, AudioEncoding.presetMusic);
      },
    );
  });

  group('LiveKitVoiceNotifier public methods', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('setCaptureEnabled updates state with isCaptureEnabled', () {
      final notifier = container.read(livekitVoiceProvider.notifier);
      expect(container.read(livekitVoiceProvider).isCaptureEnabled, isTrue);

      notifier.setCaptureEnabled(false);
      expect(container.read(livekitVoiceProvider).isCaptureEnabled, isFalse);

      notifier.setCaptureEnabled(true);
      expect(container.read(livekitVoiceProvider).isCaptureEnabled, isTrue);
    });

    test('setDeafened(true) mutes mic and saves previous state', () async {
      final notifier = container.read(livekitVoiceProvider.notifier);
      notifier.state = notifier.state.copyWith(
        isActive: true,
        isCaptureEnabled: true,
      );

      await notifier.setDeafened(true);
      final state = container.read(livekitVoiceProvider);
      expect(state.isDeafened, isTrue);
      expect(state.isCaptureEnabled, isFalse);
    });

    test(
      'setDeafened(false) restores mic state when previously unmuted',
      () async {
        final notifier = container.read(livekitVoiceProvider.notifier);
        notifier.state = notifier.state.copyWith(
          isActive: true,
          isCaptureEnabled: true,
        );

        // Deafen then undeafen
        await notifier.setDeafened(true);
        await notifier.setDeafened(false);

        final state = container.read(livekitVoiceProvider);
        expect(state.isDeafened, isFalse);
        expect(state.isCaptureEnabled, isTrue);
      },
    );

    test(
      'setDeafened keeps mic muted on undeafen if was muted before',
      () async {
        final notifier = container.read(livekitVoiceProvider.notifier);
        notifier.state = notifier.state.copyWith(
          isActive: true,
          isCaptureEnabled: false, // start muted
        );

        // Deafen then undeafen
        await notifier.setDeafened(true);
        await notifier.setDeafened(false);

        final state = container.read(livekitVoiceProvider);
        expect(state.isDeafened, isFalse);
        expect(
          state.isCaptureEnabled,
          isFalse,
        ); // stays muted since it was muted before
      },
    );

    test('leaveChannel resets state to empty', () async {
      final notifier = container.read(livekitVoiceProvider.notifier);
      notifier.state = notifier.state.copyWith(
        isActive: false,
        conversationId: 'conv-1',
        channelId: 'chan-1',
      );

      // Set isActive to false to skip sound playback path
      await notifier.leaveChannel();
      final state = container.read(livekitVoiceProvider);
      expect(state.isActive, isFalse);
      expect(state.conversationId, isNull);
      expect(state.channelId, isNull);
    });

    test('leaveChannel is idempotent when not active', () async {
      final notifier = container.read(livekitVoiceProvider.notifier);
      const state = LiveKitVoiceState.empty;
      expect(state.isActive, isFalse);

      // Should not throw
      await notifier.leaveChannel();
      expect(container.read(livekitVoiceProvider).isActive, isFalse);
    });

    test('setCaptureEnabled updates state independent of room', () {
      final notifier = container.read(livekitVoiceProvider.notifier);
      notifier.state = notifier.state.copyWith(isCaptureEnabled: true);

      // Should update state even with no room
      notifier.setCaptureEnabled(false);
      expect(container.read(livekitVoiceProvider).isCaptureEnabled, isFalse);
    });

    test('setDeafened preserves other state fields', () async {
      final notifier = container.read(livekitVoiceProvider.notifier);
      notifier.state = notifier.state.copyWith(
        isActive: true,
        conversationId: 'conv-1',
        channelId: 'chan-1',
        isCaptureEnabled: true,
      );

      await notifier.setDeafened(true);
      final state = container.read(livekitVoiceProvider);
      expect(state.conversationId, equals('conv-1'));
      expect(state.channelId, equals('chan-1'));
      expect(state.isActive, isTrue);
    });

    test('leaveChannel clears conversationId and channelId', () async {
      final notifier = container.read(livekitVoiceProvider.notifier);
      notifier.state = notifier.state.copyWith(
        isActive: true,
        conversationId: 'conv-1',
        channelId: 'chan-1',
        peerCount: 5,
      );

      await notifier.leaveChannel();
      final state = container.read(livekitVoiceProvider);
      expect(state.conversationId, isNull);
      expect(state.channelId, isNull);
      expect(state.peerCount, 0);
    });
  });
}
