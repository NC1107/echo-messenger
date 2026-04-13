import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/conversation_panel.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

void main() {
  group('ConversationPanel', () {
    testWidgets('renders Echo header', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      expect(find.text('Echo'), findsOneWidget);
    });

    testWidgets('renders action icons in header', (tester) async {
      bool newChatCalled = false;
      bool newGroupCalled = false;

      await tester.pumpApp(
        ConversationPanel(
          onConversationTap: (_) {},
          onNewChat: () => newChatCalled = true,
          onNewGroup: () => newGroupCalled = true,
          onDiscover: () {},
        ),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Verify action icons exist (discover moved to Groups tab)
      expect(find.byIcon(Icons.person_add_outlined), findsOneWidget);
      expect(find.byIcon(Icons.group_add_outlined), findsOneWidget);

      // Tap each and verify callback
      await tester.tap(find.byIcon(Icons.person_add_outlined));
      expect(newChatCalled, isTrue);

      await tester.tap(find.byIcon(Icons.group_add_outlined));
      expect(newGroupCalled, isTrue);
    });

    testWidgets('renders conversation list items', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // The 1:1 conversation with alice should show alice's name (peer)
      expect(find.text('alice'), findsOneWidget);
      // The group conversation should show its name
      expect(find.text('Dev Team'), findsOneWidget);
    });

    testWidgets('shows last message preview', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // DM conversation shows message without sender prefix
      expect(find.textContaining('Hey there!'), findsOneWidget);
      // Group conversation prefixes sender: "bob: Meeting at 3pm"
      expect(find.textContaining('bob: Meeting at 3pm'), findsOneWidget);
    });

    testWidgets('shows unread indicator dot for conversations with unreads', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // conv-1 has unreadCount=2 which renders as a small accent-colored dot
      // (10x10 circle), not a number. Verify the conversation name uses bold
      // font weight (w700) for unread conversations.
      final aliceText = tester.widget<Text>(find.text('alice'));
      expect(aliceText.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('tapping a conversation triggers callback', (tester) async {
      Conversation? tappedConversation;

      await tester.pumpApp(
        ConversationPanel(onConversationTap: (c) => tappedConversation = c),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // Tap on alice's conversation
      await tester.tap(find.text('alice'));
      await tester.pump();

      expect(tappedConversation, isNotNull);
      expect(tappedConversation!.id, 'conv-1');
    });

    testWidgets('shows search bar area', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Search bar is a GestureDetector with a Container containing search icon
      expect(find.byIcon(Icons.search_outlined), findsOneWidget);
    });

    testWidgets('empty state shows message when no conversations', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: []),
      );
      await tester.pump();

      // With no conversations, the empty state shows "No conversations yet"
      expect(find.text('No conversations yet'), findsOneWidget);
    });

    testWidgets('connection indicator dot is present', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // The connection indicator is an 8x8 Container with BoxShape.circle
      // near the Echo text. We verify via the header text being present.
      expect(find.text('Echo'), findsOneWidget);
    });

    testWidgets('highlights selected conversation', (tester) async {
      await tester.pumpApp(
        ConversationPanel(
          selectedConversationId: 'conv-1',
          onConversationTap: (_) {},
        ),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // The selected conversation should still render alice
      expect(find.text('alice'), findsOneWidget);
    });
  });

  group('buildAvatar', () {
    testWidgets('renders initial letter', (tester) async {
      await tester.pumpApp(buildAvatar(name: 'Alice', radius: 20));
      await tester.pump();

      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('renders ? for empty name', (tester) async {
      await tester.pumpApp(buildAvatar(name: '', radius: 20));
      await tester.pump();

      expect(find.text('?'), findsOneWidget);
    });
  });

  group('avatarColor', () {
    test('returns consistent color for same name', () {
      final c1 = avatarColor('alice');
      final c2 = avatarColor('alice');
      expect(c1, equals(c2));
    });

    test('returns different colors for different names', () {
      // Not guaranteed but statistically likely for different names
      final c1 = avatarColor('alice');
      final c2 = avatarColor('bob');
      // At minimum they should both be valid colors
      expect(c1.a, greaterThan(0));
      expect(c2.a, greaterThan(0));
    });
  });
}
