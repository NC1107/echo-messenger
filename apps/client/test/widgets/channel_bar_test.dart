import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/widgets/channel_bar.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

class _FakeChannelsNotifier extends ChannelsNotifier {
  _FakeChannelsNotifier(super.ref) : super() {
    state = ChannelsState(
      channelsByConversation: {
        'conv-1': const [
          GroupChannel(
            id: 'voice-1',
            conversationId: 'conv-1',
            name: 'lounge',
            kind: 'voice',
            position: 0,
            category: 'Voice Channels',
            createdAt: '2026-01-01T00:00:00Z',
          ),
        ],
      },
      voiceSessionsByChannel: const {'voice-1': []},
    );
  }

  int joinCalls = 0;
  int leaveCalls = 0;

  @override
  Future<bool> joinVoiceChannel(String conversationId, String channelId) async {
    joinCalls++;
    return true;
  }

  @override
  Future<bool> leaveVoiceChannel(
    String conversationId,
    String channelId,
  ) async {
    leaveCalls++;
    return true;
  }

  @override
  Future<void> loadChannels(String conversationId) async {}

  @override
  Future<void> loadVoiceSessions(
    String conversationId,
    String channelId,
  ) async {}

  @override
  Future<bool> updateVoiceState({
    required String conversationId,
    required String channelId,
    required bool isMuted,
    required bool isDeafened,
    required bool pushToTalk,
  }) async {
    return true;
  }
}

class _FakeVoiceRtcNotifier extends LiveKitVoiceNotifier {
  _FakeVoiceRtcNotifier(super.ref);

  int joinCalls = 0;
  int leaveCalls = 0;

  @override
  Future<void> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async {
    joinCalls++;
    state = state.copyWith(
      isActive: true,
      isJoining: false,
      conversationId: conversationId,
      channelId: channelId,
    );
  }

  @override
  Future<void> leaveChannel() async {
    leaveCalls++;
    // Don't set state here -- may be called during widget dispose when the
    // element is already defunct, which would trigger a framework assertion.
  }
}

class _FakeVoiceSettingsNotifier extends VoiceSettingsNotifier {
  _FakeVoiceSettingsNotifier();
}

void main() {
  group('ChannelBar voice join confirmation', () {
    testWidgets('asks for confirmation before joining voice', (tester) async {
      late _FakeChannelsNotifier fakeChannels;
      late _FakeVoiceRtcNotifier fakeVoiceRtc;

      await tester.pumpApp(
        ChannelBar(
          conversationId: 'conv-1',
          onTextChannelChanged: (_) {},
          onVoiceChannelChanged: (_) {},
        ),
        overrides: [
          authOverride(loggedInAuthState),
          webSocketOverride(),
          channelsProvider.overrideWith((ref) {
            fakeChannels = _FakeChannelsNotifier(ref);
            return fakeChannels;
          }),
          voiceRtcProvider.overrideWith((ref) {
            fakeVoiceRtc = _FakeVoiceRtcNotifier(ref);
            return fakeVoiceRtc;
          }),
          voiceSettingsProvider.overrideWith(
            (ref) => _FakeVoiceSettingsNotifier(),
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('lounge'), findsOneWidget);

      await tester.tap(find.text('lounge').first);
      await tester.pumpAndSettle();

      expect(find.text('Join Voice Channel?'), findsOneWidget);
      expect(fakeChannels.joinCalls, 0);
      expect(fakeVoiceRtc.joinCalls, 0);
    });

    testWidgets('joins voice only after confirmation', (tester) async {
      late _FakeChannelsNotifier fakeChannels;
      late _FakeVoiceRtcNotifier fakeVoiceRtc;
      String? activeVoice;

      await tester.pumpApp(
        StatefulBuilder(
          builder: (context, setState) => ChannelBar(
            conversationId: 'conv-1',
            activeVoiceChannelId: activeVoice,
            onTextChannelChanged: (_) {},
            onVoiceChannelChanged: (channelId) {
              setState(() => activeVoice = channelId);
            },
          ),
        ),
        overrides: [
          authOverride(loggedInAuthState),
          webSocketOverride(),
          channelsProvider.overrideWith((ref) {
            fakeChannels = _FakeChannelsNotifier(ref);
            return fakeChannels;
          }),
          voiceRtcProvider.overrideWith((ref) {
            fakeVoiceRtc = _FakeVoiceRtcNotifier(ref);
            return fakeVoiceRtc;
          }),
          voiceSettingsProvider.overrideWith(
            (ref) => _FakeVoiceSettingsNotifier(),
          ),
        ],
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('lounge').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(fakeChannels.joinCalls, 1);
      expect(fakeVoiceRtc.joinCalls, 1);
      expect(activeVoice, 'voice-1');
    });

    testWidgets('tapping active voice channel shows lounge', (tester) async {
      late _FakeChannelsNotifier fakeChannels;
      late _FakeVoiceRtcNotifier fakeVoiceRtc;
      String? activeVoice;
      var showLoungeCalls = 0;

      await tester.pumpApp(
        StatefulBuilder(
          builder: (context, setState) => ChannelBar(
            conversationId: 'conv-1',
            activeVoiceChannelId: activeVoice,
            onTextChannelChanged: (_) {},
            onVoiceChannelChanged: (channelId) {
              setState(() => activeVoice = channelId);
            },
            onShowLounge: () => showLoungeCalls++,
          ),
        ),
        overrides: [
          authOverride(loggedInAuthState),
          webSocketOverride(),
          channelsProvider.overrideWith((ref) {
            fakeChannels = _FakeChannelsNotifier(ref);
            return fakeChannels;
          }),
          voiceRtcProvider.overrideWith((ref) {
            fakeVoiceRtc = _FakeVoiceRtcNotifier(ref);
            return fakeVoiceRtc;
          }),
          voiceSettingsProvider.overrideWith(
            (ref) => _FakeVoiceSettingsNotifier(),
          ),
        ],
      );
      await tester.pumpAndSettle();

      // Join first.
      await tester.tap(find.text('lounge').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(fakeChannels.joinCalls, 1);
      expect(fakeVoiceRtc.joinCalls, 1);
      expect(activeVoice, 'voice-1');

      // Tap active channel again -- should show lounge, not leave.
      await tester.tap(find.text('lounge').first);
      await tester.pumpAndSettle();

      expect(showLoungeCalls, 1);
      expect(fakeChannels.leaveCalls, 0);
      expect(fakeVoiceRtc.leaveCalls, 0);
      expect(activeVoice, 'voice-1');
    });
  });
}
