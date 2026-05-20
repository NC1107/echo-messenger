import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/widgets/channel_column.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

/// Smoke tests for the new Slack/Discord-style channel column.
/// Verifies rendering of categories, text + voice rows, voice-member
/// nesting, and the selected-state highlight on the active text channel.
void main() {
  Conversation conv(String displayName) => Conversation(
    id: 'c1',
    isGroup: true,
    name: displayName,
    members: const [
      ConversationMember(userId: 'me', username: 'me'),
      ConversationMember(userId: 'u2', username: 'jane'),
    ],
  );

  GroupChannel text(String id, String name, {int pos = 0}) => GroupChannel(
    id: id,
    conversationId: 'c1',
    name: name,
    kind: 'text',
    position: pos,
    createdAt: '',
  );

  GroupChannel voice(String id, String name, {int pos = 0}) => GroupChannel(
    id: id,
    conversationId: 'c1',
    name: name,
    kind: 'voice',
    position: pos,
    category: 'Voice Channels',
    createdAt: '',
  );

  Override channelsOverride({
    required Map<String, List<GroupChannel>> channelsByConversation,
    Map<String, List<VoiceSessionMember>> voiceSessionsByChannel = const {},
  }) {
    return channelsProvider.overrideWith(
      () => _StubChannelsNotifier(
        ChannelsState(
          channelsByConversation: channelsByConversation,
          voiceSessionsByChannel: voiceSessionsByChannel,
        ),
      ),
    );
  }

  group('ChannelColumn', () {
    testWidgets('renders text + voice category headers and channel rows', (
      tester,
    ) async {
      await tester.pumpApp(
        ChannelColumn(
          conversation: conv('Echo Devs'),
          selectedTextChannelId: 't1',
          onTextChannelChanged: (_) {},
        ),
        overrides: [
          channelsOverride(
            channelsByConversation: {
              'c1': [
                text('t1', 'general'),
                text('t2', 'releases', pos: 1),
                voice('v1', 'lounge'),
              ],
            },
          ),
        ],
      );

      expect(find.text('TEXT CHANNELS'), findsOneWidget);
      expect(find.text('VOICE CHANNELS'), findsOneWidget);
      expect(find.text('general'), findsOneWidget);
      expect(find.text('releases'), findsOneWidget);
      expect(find.text('lounge'), findsOneWidget);
    });

    testWidgets(
      'selected text channel fires onTextChannelChanged with its id',
      (tester) async {
        String? lastSelected;
        await tester.pumpApp(
          ChannelColumn(
            conversation: conv('Echo Devs'),
            selectedTextChannelId: null,
            onTextChannelChanged: (id) => lastSelected = id,
          ),
          overrides: [
            channelsOverride(
              channelsByConversation: {
                'c1': [text('t1', 'general'), text('t2', 'releases', pos: 1)],
              },
            ),
          ],
        );
        await tester.tap(find.text('releases'));
        await tester.pump();
        expect(lastSelected, 't2');
      },
    );

    testWidgets('voice members render nested under the voice row when active', (
      tester,
    ) async {
      await tester.pumpApp(
        ChannelColumn(
          conversation: conv('Echo Devs'),
          selectedTextChannelId: 't1',
          onTextChannelChanged: (_) {},
        ),
        overrides: [
          channelsOverride(
            channelsByConversation: {
              'c1': [text('t1', 'general'), voice('v1', 'lounge')],
            },
            voiceSessionsByChannel: {
              'v1': const [
                VoiceSessionMember(
                  channelId: 'v1',
                  userId: 'u2',
                  username: 'jane',
                  isMuted: false,
                  isDeafened: false,
                  pushToTalk: false,
                  joinedAt: '',
                  updatedAt: '',
                ),
              ],
            },
          ),
        ],
      );
      expect(find.text('jane'), findsOneWidget);
      // Member count badge on the voice row.
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('voice row with no members hides the count', (tester) async {
      await tester.pumpApp(
        ChannelColumn(
          conversation: conv('Echo Devs'),
          selectedTextChannelId: 't1',
          onTextChannelChanged: (_) {},
        ),
        overrides: [
          channelsOverride(
            channelsByConversation: {
              'c1': [voice('v1', 'lounge')],
            },
          ),
        ],
      );
      expect(find.text('lounge'), findsOneWidget);
      // No '0' badge — the count only renders when at least one member.
      expect(find.text('0'), findsNothing);
    });
  });
}

class _StubChannelsNotifier extends Channels {
  _StubChannelsNotifier(this._initial);
  final ChannelsState _initial;

  @override
  ChannelsState build() => _initial;
}
