import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/widgets/mobile_channel_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/pump_app.dart';

/// Smoke tests for the Discord-style mobile drawer: the group rail
/// switches conversations and channel taps pop the drawer.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Conversation conv(String id, String name) => Conversation(
    id: id,
    isGroup: true,
    name: name,
    members: const [ConversationMember(userId: 'me', username: 'me')],
  );

  GroupChannel text(String id, String name, {int pos = 0}) => GroupChannel(
    id: id,
    conversationId: 'c1',
    name: name,
    kind: 'text',
    position: pos,
    createdAt: '',
  );

  Override channelsOverride(Map<String, List<GroupChannel>> byConv) =>
      channelsProvider.overrideWith(
        () => _StubChannels(
          ChannelsState(
            channelsByConversation: byConv,
            voiceSessionsByChannel: const {},
          ),
        ),
      );

  Override conversationsOverride(List<Conversation> convs) =>
      conversationsProvider.overrideWith(
        () => _StubConversations(ConversationsState(conversations: convs)),
      );

  Future<void> openDrawer(WidgetTester tester) async {
    // `pumpApp` already wraps in an outer Scaffold(body: widget); the
    // drawer lives on the inner one, so grab the LAST Scaffold to find
    // a ScaffoldState that actually has a drawer attached.
    final scaffoldFinder = find.byType(Scaffold);
    final scaffoldState = tester.state<ScaffoldState>(scaffoldFinder.last);
    scaffoldState.openDrawer();
    await tester.pumpAndSettle();
  }

  group('MobileChannelDrawer', () {
    testWidgets('tapping a text channel closes the drawer and fires '
        'onTextChannelChanged', (tester) async {
      String? lastChannel;
      bool drawerOpen = true;
      await tester.pumpApp(
        Scaffold(
          drawer: MobileChannelDrawer(
            conversation: conv('c1', 'Echo Devs'),
            selectedTextChannelId: null,
            onTextChannelChanged: (id) => lastChannel = id,
            onConversationSelected: (_) {},
          ),
          body: Builder(
            builder: (ctx) {
              return TextButton(
                onPressed: () => Scaffold.of(ctx).openDrawer(),
                child: const Text('open'),
              );
            },
          ),
          onDrawerChanged: (open) => drawerOpen = open,
        ),
        overrides: [
          channelsOverride({
            'c1': [text('t1', 'general'), text('t2', 'releases', pos: 1)],
          }),
          conversationsOverride([conv('c1', 'Echo Devs')]),
        ],
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(drawerOpen, isTrue);
      await tester.tap(find.text('releases'));
      await tester.pumpAndSettle();
      expect(lastChannel, 't2');
      expect(drawerOpen, isFalse);
    });

    testWidgets('group rail lists other groups and forwards taps', (
      tester,
    ) async {
      String? switched;
      await tester.pumpApp(
        Scaffold(
          drawer: MobileChannelDrawer(
            conversation: conv('c1', 'Echo Devs'),
            selectedTextChannelId: null,
            onTextChannelChanged: (_) {},
            onConversationSelected: (id) => switched = id,
          ),
        ),
        overrides: [
          channelsOverride({
            'c1': [text('t1', 'general')],
          }),
          conversationsOverride([
            conv('c1', 'Echo Devs'),
            conv('c2', 'Taco Lovers'),
          ]),
        ],
      );
      await openDrawer(tester);
      // Both groups appear as avatars in the rail (initial letter only).
      expect(find.bySemanticsLabel('group Echo Devs'), findsOneWidget);
      expect(find.bySemanticsLabel('group Taco Lovers'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('group Taco Lovers'));
      await tester.pumpAndSettle();
      expect(switched, 'c2');
    });
  });
}

class _StubChannels extends Channels {
  _StubChannels(this._initial);
  final ChannelsState _initial;

  @override
  ChannelsState build() => _initial;
}

class _StubConversations extends ConversationsNotifier {
  _StubConversations(this._initial);
  final ConversationsState _initial;

  @override
  ConversationsState build() => _initial;
}
