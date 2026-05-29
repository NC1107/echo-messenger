import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/livekit_voice/livekit_voice_provider.dart';
import 'package:echo_app/src/widgets/voice_dock.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeLiveKitNotifier extends LiveKitVoiceNotifier {
  _FakeLiveKitNotifier({LiveKitVoiceState? initial}) : _initial = initial;
  final LiveKitVoiceState? _initial;

  @override
  LiveKitVoiceState build() => _initial ?? LiveKitVoiceState.empty;

  @override
  Future<void> leaveChannel() async {
    state = LiveKitVoiceState.empty;
  }

  @override
  Future<bool> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async => true;
}

class _FakeChannelsNotifier extends Channels {
  @override
  ChannelsState build() => const ChannelsState(
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

  @override
  Future<void> loadChannels(String conversationId) async {}

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

const _activeVoice = LiveKitVoiceState(
  isActive: true,
  conversationId: 'conv-1',
  channelId: 'voice-1',
);

List<Override> _overrides({required LiveKitVoiceState state}) => [
  ...standardOverrides(),
  livekitVoiceProvider.overrideWith(() => _FakeLiveKitNotifier(initial: state)),
  channelsProvider.overrideWith(_FakeChannelsNotifier.new),
];

void main() {
  group('VoiceDock', () {
    testWidgets('renders nothing when voice is inactive', (tester) async {
      await tester.pumpApp(
        const VoiceDock(),
        overrides: _overrides(state: LiveKitVoiceState.empty),
      );
      await tester.pump();

      // No channel name, no hangup button.
      expect(find.text('General'), findsNothing);
      expect(find.byIcon(Icons.call_end), findsNothing);
    });

    testWidgets('renders channel name, status and hangup when active', (
      tester,
    ) async {
      await tester.pumpApp(
        const VoiceDock(),
        overrides: _overrides(state: _activeVoice),
      );
      await tester.pump();

      expect(find.byIcon(Icons.call_end), findsOneWidget);
      // Status label (no peers yet -> "Waiting for peers").
      expect(find.text('Waiting for peers'), findsOneWidget);
      // Secondary line embeds the channel name.
      expect(find.textContaining('General'), findsOneWidget);
    });

    testWidgets('tapping the dock surface fires onNavigateToLounge', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpApp(
        VoiceDock(onNavigateToLounge: () => calls++),
        overrides: _overrides(state: _activeVoice),
      );
      await tester.pump();

      // Tap the status text — it sits inside the GestureDetector that
      // wraps the dock body.
      await tester.tap(find.text('Waiting for peers'));
      await tester.pump();
      expect(calls, 1);
    });

    testWidgets('collapsed dock only paints the compact column controls', (
      tester,
    ) async {
      await tester.pumpApp(
        const VoiceDock(collapsed: true),
        overrides: _overrides(state: _activeVoice),
      );
      await tester.pump();

      // No status label in compact mode.
      expect(find.text('Waiting for peers'), findsNothing);
      // Still has a hangup affordance.
      expect(find.byIcon(Icons.call_end), findsOneWidget);
    });
  });
}
