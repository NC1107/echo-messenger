import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/conversation_item.dart';

import '../helpers/pump_app.dart';

Conversation _makeConversation({
  String id = 'conv-1',
  String? name,
  bool isGroup = false,
  String? lastMessage,
  String? lastMessageTimestamp,
  String? lastMessageSender,
  int unreadCount = 0,
  bool isMuted = false,
  List<ConversationMember> members = const [],
}) {
  return Conversation(
    id: id,
    name: name,
    isGroup: isGroup,
    lastMessage: lastMessage,
    lastMessageTimestamp: lastMessageTimestamp,
    lastMessageSender: lastMessageSender,
    unreadCount: unreadCount,
    isMuted: isMuted,
    members: members,
  );
}

void main() {
  group('ConversationItem', () {
    testWidgets('renders conversation display name for 1:1 chat', (
      tester,
    ) async {
      final conv = _makeConversation(
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.text('alice'), findsOneWidget);
    });

    testWidgets('renders group name for group conversation', (tester) async {
      final conv = _makeConversation(
        name: 'Dev Team',
        isGroup: true,
        members: const [
          ConversationMember(userId: 'u1', username: 'alice'),
          ConversationMember(userId: 'u2', username: 'bob'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '09:00',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.text('Dev Team'), findsOneWidget);
    });

    testWidgets('renders last message preview', (tester) async {
      final conv = _makeConversation(
        lastMessage: 'Hey there!',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.textContaining('Hey there!'), findsOneWidget);
    });

    testWidgets('shows unread indicator when unreadCount > 0', (tester) async {
      final conv = _makeConversation(
        unreadCount: 3,
        lastMessage: 'New message',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      // Unread indicator is a 10x10 circle Container -- find decorated
      // containers. The name text should use bold font when unread.
      final nameText = tester.widget<Text>(find.text('alice'));
      expect(nameText.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('does not show bold name when unreadCount is 0', (
      tester,
    ) async {
      final conv = _makeConversation(
        unreadCount: 0,
        lastMessage: 'Old message',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      final nameText = tester.widget<Text>(find.text('alice'));
      expect(nameText.style?.fontWeight, FontWeight.w500);
    });

    testWidgets('strips markdown bold markers from preview', (tester) async {
      final conv = _makeConversation(
        lastMessage: '**bold text**',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      // The ** markers should be stripped, showing just the text
      expect(find.textContaining('bold text'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing);
    });

    testWidgets('strips markdown italic markers from preview', (tester) async {
      final conv = _makeConversation(
        lastMessage: '*italic text*',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.textContaining('italic text'), findsOneWidget);
    });

    testWidgets('strips inline code markers from preview', (tester) async {
      final conv = _makeConversation(
        lastMessage: '`some code`',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.textContaining('some code'), findsOneWidget);
      // Backticks should be stripped
      expect(find.textContaining('`'), findsNothing);
    });

    testWidgets('renders timestamp string', (tester) async {
      final conv = _makeConversation(
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '2:45 PM',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.text('2:45 PM'), findsOneWidget);
    });

    testWidgets('shows pin icon when isPinned is true', (tester) async {
      final conv = _makeConversation(
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: true,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.push_pin), findsOneWidget);
    });

    testWidgets('does not show pin icon when isPinned is false', (
      tester,
    ) async {
      final conv = _makeConversation(
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.push_pin), findsNothing);
    });

    testWidgets('shows muted icon when isMuted is true and has snippet', (
      tester,
    ) async {
      final conv = _makeConversation(
        isMuted: true,
        lastMessage: 'test',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    });

    testWidgets('onTap callback fires when tapped', (tester) async {
      var tapped = false;
      final conv = _makeConversation(
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () => tapped = true,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('alice'));
      expect(tapped, isTrue);
    });

    testWidgets('image marker in lastMessage shows image label', (
      tester,
    ) async {
      final conv = _makeConversation(
        lastMessage: '[img:/api/media/photo.png]',
        lastMessageSender: 'alice',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      // Should show the photo media label, not the raw marker
      expect(find.textContaining('Photo'), findsOneWidget);
      expect(find.textContaining('[img:'), findsNothing);
    });

    testWidgets('sender label prepends "You" for own messages in groups', (
      tester,
    ) async {
      final conv = _makeConversation(
        isGroup: true,
        lastMessage: 'my message',
        lastMessageSender: 'me',
        members: const [
          ConversationMember(userId: 'peer-id', username: 'alice'),
          ConversationMember(userId: 'my-id', username: 'me'),
        ],
      );
      await tester.pumpApp(
        ConversationItem(
          conversation: conv,
          myUserId: 'my-id',
          isSelected: false,
          isPinned: false,
          isPeerOnline: false,
          timestamp: '10:30',
          onTap: () {},
        ),
      );
      await tester.pump();

      expect(find.textContaining('You:'), findsOneWidget);
    });
  });
}
