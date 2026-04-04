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

    testWidgets('non-owner still sees leave group action', (tester) async {
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

      expect(find.text('Leave Group'), findsOneWidget);
      expect(find.text('Delete Group'), findsNothing);
    });
  });
}
