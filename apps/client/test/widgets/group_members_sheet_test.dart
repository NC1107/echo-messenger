import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/group_members_sheet.dart';
import 'package:echo_app/src/widgets/member_role.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

void main() {
  const groupConversation = Conversation(
    id: 'group-sheet-1',
    name: 'Test Group',
    isGroup: true,
    members: [
      ConversationMember(
        userId: 'test-user-id',
        username: 'testuser',
        role: 'owner',
      ),
      ConversationMember(
        userId: 'user-alice',
        username: 'alice',
        role: 'admin',
      ),
      ConversationMember(userId: 'user-bob', username: 'bob'),
    ],
  );

  group('GroupMembersSheet', () {
    testWidgets('renders all member names when opened', (tester) async {
      await tester.pumpApp(
        const GroupMembersSheet(conversation: groupConversation),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      expect(find.text('testuser'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
    });

    testWidgets('renders Members header title', (tester) async {
      await tester.pumpApp(
        const GroupMembersSheet(conversation: groupConversation),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Members'), findsOneWidget);
    });

    testWidgets('marks roles with pills, not leading icons (mobile sheet)', (
      tester,
    ) async {
      await tester.pumpApp(
        const GroupMembersSheet(conversation: groupConversation),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      // The comfortable-density mobile sheet marks roles with the Owner/Admin
      // pill only; the star/shield leading icon is reserved for the compact
      // desktop rail (see MemberListRow). The "Owner and Admin badge chips"
      // test below covers the pills themselves.
      expect(find.byType(MemberRoleIcon), findsNothing);
    });

    testWidgets('shows Owner and Admin badge chips', (tester) async {
      await tester.pumpApp(
        const GroupMembersSheet(conversation: groupConversation),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
    });

    testWidgets('shows spinner when conversation has no members', (
      tester,
    ) async {
      const emptyGroup = Conversation(
        id: 'group-empty',
        name: 'Empty Group',
        isGroup: true,
        members: [],
      );

      await tester.pumpApp(
        const GroupMembersSheet(conversation: emptyGroup),
        overrides: standardOverrides(),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('showGroupMembersSheet opens sheet via navigator', (
      tester,
    ) async {
      await tester.pumpApp(
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showGroupMembersSheet(ctx, groupConversation),
            child: const Text('open'),
          ),
        ),
        overrides: standardOverrides(),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Sheet title and member names are visible.
      expect(find.text('Members'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
    });
  });
}
