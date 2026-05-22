import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/members_panel.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

void main() {
  group('MembersPanel group actions', () {
    testWidgets('owner does not see delete or leave action in members panel', (
      tester,
    ) async {
      const ownerConversation = Conversation(
        id: 'group-1',
        name: 'Core Team',
        isGroup: true,
        members: [
          ConversationMember(
            userId: 'test-user-id',
            username: 'testuser',
            role: 'owner',
          ),
          ConversationMember(userId: 'user-1', username: 'alice'),
        ],
      );

      await tester.pumpApp(
        const MembersPanel(conversation: ownerConversation),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Delete Group'), findsNothing);
      expect(find.text('Leave Group'), findsNothing);
    });

    testWidgets('non-owner does not see leave group in sidebar', (
      tester,
    ) async {
      const memberConversation = Conversation(
        id: 'group-2',
        name: 'Core Team',
        isGroup: true,
        members: [
          ConversationMember(
            userId: 'test-user-id',
            username: 'testuser',
            role: 'member',
          ),
          ConversationMember(userId: 'user-2', username: 'bob', role: 'owner'),
        ],
      );

      await tester.pumpApp(
        const MembersPanel(conversation: memberConversation),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      // Leave Group was removed from the members sidebar.
      expect(find.text('Leave Group'), findsNothing);
      expect(find.text('Delete Group'), findsNothing);
    });
  });

  group('MembersPanel width', () {
    const conv = Conversation(
      id: 'g',
      name: 'G',
      isGroup: true,
      members: [
        ConversationMember(
          userId: 'test-user-id',
          username: 'testuser',
          role: 'owner',
        ),
      ],
    );

    testWidgets('honors the explicit width parameter', (tester) async {
      await tester.pumpApp(
        const MembersPanel(conversation: conv, width: 360),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(MembersPanel));
      expect(size.width, 360);
    });

    testWidgets('falls back to defaultWidth when no width is passed', (
      tester,
    ) async {
      await tester.pumpApp(
        const MembersPanel(conversation: conv),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(MembersPanel));
      expect(size.width, MembersPanel.defaultWidth);
    });

    test('width bounds are sane', () {
      expect(MembersPanel.minWidth, lessThan(MembersPanel.defaultWidth));
      expect(MembersPanel.defaultWidth, lessThan(MembersPanel.maxWidth));
    });
  });
}
