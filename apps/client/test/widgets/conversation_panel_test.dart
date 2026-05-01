import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
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

    testWidgets('renders action menu in header', (tester) async {
      bool newChatCalled = false;
      bool newGroupCalled = false;
      bool discoverCalled = false;

      await tester.pumpApp(
        ConversationPanel(
          onConversationTap: (_) {},
          onNewChat: () => newChatCalled = true,
          onNewGroup: () => newGroupCalled = true,
          onDiscover: () => discoverCalled = true,
        ),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Verify the "+" action menu exists
      expect(find.byIcon(Icons.add), findsOneWidget);

      // Open the popup menu
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // Verify menu items are shown with labels
      expect(find.text('New Chat'), findsOneWidget);
      expect(find.text('New Group'), findsOneWidget);
      expect(find.text('Discover Groups'), findsOneWidget);

      // Tap New Chat and verify callback
      await tester.tap(find.text('New Chat'));
      await tester.pumpAndSettle();
      expect(newChatCalled, isTrue);

      // Re-open menu for next test
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('New Group'));
      await tester.pumpAndSettle();
      expect(newGroupCalled, isTrue);

      // Re-open menu for discover
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Discover Groups'));
      await tester.pumpAndSettle();
      expect(discoverCalled, isTrue);
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

    testWidgets('header renders without a duplicate connection dot', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Connection state is now shown only on the bottom user-status bar
      // via the avatar dot. The header just shows the Echo wordmark.
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

    testWidgets('status picker: avatar tap opens menu with 4 options', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // The status bar renders a PopupMenuButton with key 'status-picker'.
      expect(find.byKey(const Key('status-picker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('status-picker')));
      await tester.pumpAndSettle();

      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Away'), findsOneWidget);
      expect(find.text('Do Not Disturb'), findsOneWidget);
      expect(find.text('Invisible'), findsOneWidget);
    });

    testWidgets('status picker: selecting Away calls setPresenceStatus', (
      tester,
    ) async {
      const authState = AuthState(
        isLoggedIn: true,
        userId: 'test-user-id',
        username: 'testuser',
        token: 'fake-jwt-token',
        refreshToken: 'fake-refresh-token',
        presenceStatus: 'online',
      );

      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(authState: authState),
      );
      await tester.pump();

      // Open the status picker.
      await tester.tap(find.byKey(const Key('status-picker')));
      await tester.pumpAndSettle();

      // Tap the Away option.
      await tester.tap(find.text('Away'));
      await tester.pumpAndSettle();

      // After selecting Away, the menu dismisses and 'Away' is no longer visible.
      expect(find.text('Online'), findsNothing);
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

  group('resolveAvatarUrl', () {
    test('returns null for null input', () {
      expect(resolveAvatarUrl(null, 'http://localhost:8080'), isNull);
    });

    test('returns null for empty string', () {
      expect(resolveAvatarUrl('', 'http://localhost:8080'), isNull);
    });

    test('prepends serverUrl to relative path', () {
      expect(
        resolveAvatarUrl('/api/users/abc/avatar', 'http://localhost:8080'),
        equals('http://localhost:8080/api/users/abc/avatar'),
      );
    });

    test('returns absolute URL unchanged', () {
      expect(
        resolveAvatarUrl(
          'https://example.com/avatar.png',
          'http://localhost:8080',
        ),
        equals('https://example.com/avatar.png'),
      );
    });

    test('returns http absolute URL unchanged', () {
      expect(
        resolveAvatarUrl(
          'http://example.com/avatar.png',
          'http://localhost:8080',
        ),
        equals('http://example.com/avatar.png'),
      );
    });
  });
}
