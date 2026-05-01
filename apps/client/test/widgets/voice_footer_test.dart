import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/livekit_voice_provider.dart';
import 'package:echo_app/src/widgets/voice_footer.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeLiveKitNotifier extends LiveKitVoiceNotifier {
  _FakeLiveKitNotifier(super.ref, {LiveKitVoiceState? initial}) {
    if (initial != null) state = initial;
  }

  int leaveCallCount = 0;

  @override
  Future<void> leaveChannel() async {
    leaveCallCount++;
    state = const LiveKitVoiceState(isActive: false);
  }

  @override
  Future<void> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async {}
}

class _FakeChannelsNotifier extends ChannelsNotifier {
  _FakeChannelsNotifier(super.ref) {
    state = const ChannelsState(
      channelsByConversation: {
        'conv-1': [
          GroupChannel(
            id: 'voice-1',
            conversationId: 'conv-1',
            name: 'General',
            kind: 'voice',
            position: 0,
            category: 'Voice Channels',
            createdAt: '2026-01-01T00:00:00Z',
          ),
        ],
      },
    );
  }

  @override
  Future<void> loadChannels(String conversationId) async {}

  @override
  Future<void> loadVoiceSessions(
    String conversationId,
    String channelId,
  ) async {}

  @override
  Future<bool> joinVoiceChannel(
    String conversationId,
    String channelId,
  ) async => true;

  @override
  Future<bool> leaveVoiceChannel(
    String conversationId,
    String channelId,
  ) async => true;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _activeVoiceState = LiveKitVoiceState(
  isActive: true,
  conversationId: 'conv-1',
  channelId: 'voice-1',
);

const _inactiveVoiceState = LiveKitVoiceState(isActive: false);

List<Override> _overrides({required LiveKitVoiceState voiceState}) {
  return [
    ...standardOverrides(),
    livekitVoiceProvider.overrideWith(
      (ref) => _FakeLiveKitNotifier(ref, initial: voiceState),
    ),
    channelsProvider.overrideWith((ref) => _FakeChannelsNotifier(ref)),
  ];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('VoiceFooter', () {
    testWidgets('hidden when voice is inactive', (tester) async {
      await tester.pumpApp(
        const VoiceFooter(),
        overrides: _overrides(voiceState: _inactiveVoiceState),
      );
      await tester.pump();

      expect(find.byType(VoiceFooter), findsOneWidget);
      // No room name text, no disconnect button
      expect(find.text('General'), findsNothing);
      expect(find.byIcon(Icons.call_end), findsNothing);
    });

    testWidgets('renders room name and disconnect button when active', (
      tester,
    ) async {
      await tester.pumpApp(
        const VoiceFooter(),
        overrides: _overrides(voiceState: _activeVoiceState),
      );
      await tester.pump();

      expect(find.text('General'), findsOneWidget);
      expect(find.byIcon(Icons.call_end), findsOneWidget);
    });

    testWidgets('disconnect button calls leaveChannel', (tester) async {
      late _FakeLiveKitNotifier fakeVoice;

      await tester.pumpApp(
        const VoiceFooter(),
        overrides: [
          ...standardOverrides(),
          livekitVoiceProvider.overrideWith((ref) {
            fakeVoice = _FakeLiveKitNotifier(ref, initial: _activeVoiceState);
            return fakeVoice;
          }),
          channelsProvider.overrideWith((ref) => _FakeChannelsNotifier(ref)),
        ],
      );
      await tester.pump();

      expect(find.byIcon(Icons.call_end), findsOneWidget);
      await tester.tap(find.byIcon(Icons.call_end));
      await tester.pump();

      expect(fakeVoice.leaveCallCount, 1);
    });

    testWidgets('tapping footer body fires onNavigateToLounge', (tester) async {
      var navigateCalls = 0;

      await tester.pumpApp(
        VoiceFooter(onNavigateToLounge: () => navigateCalls++),
        overrides: _overrides(voiceState: _activeVoiceState),
      );
      await tester.pump();

      // Tap the InkWell body (room name area), not the disconnect icon
      await tester.tap(find.text('General'));
      await tester.pump();

      expect(navigateCalls, 1);
    });
  });
}
