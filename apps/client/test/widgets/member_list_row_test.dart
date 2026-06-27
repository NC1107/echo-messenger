import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/member_list_row.dart';
import 'package:echo_app/src/widgets/member_role.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

void main() {
  group('MemberListRow', () {
    testWidgets('renders the username', (tester) async {
      await tester.pumpApp(
        const MemberListRow(
          member: ConversationMember(userId: 'u1', username: 'alice'),
        ),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      expect(find.text('alice'), findsOneWidget);
    });

    testWidgets('compact shows the leading role icon, not the pill', (
      tester,
    ) async {
      await tester.pumpApp(
        const MemberListRow(
          member: ConversationMember(
            userId: 'u2',
            username: 'owner1',
            role: 'owner',
          ),
          density: MemberRowDensity.compact,
        ),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MemberRoleIcon), findsOneWidget);
      expect(find.byType(MemberRoleBadge), findsNothing);
    });

    testWidgets('comfortable shows the trailing role pill, not the icon', (
      tester,
    ) async {
      await tester.pumpApp(
        const MemberListRow(
          member: ConversationMember(
            userId: 'u3',
            username: 'admin1',
            role: 'admin',
          ),
          density: MemberRowDensity.comfortable,
        ),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MemberRoleBadge), findsOneWidget);
      expect(find.byType(MemberRoleIcon), findsNothing);
    });

    testWidgets('tapping the row fires onTap', (tester) async {
      var tapped = false;
      await tester.pumpApp(
        MemberListRow(
          member: const ConversationMember(userId: 'u4', username: 'bob'),
          onTap: () => tapped = true,
        ),
        overrides: standardOverrides(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('bob'));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });
}
