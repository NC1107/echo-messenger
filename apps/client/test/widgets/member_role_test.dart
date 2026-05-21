import 'package:echo_app/src/widgets/member_role.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  group('MemberRoleIcon', () {
    testWidgets('renders amber star for owner', (tester) async {
      await tester.pumpApp(const MemberRoleIcon(role: 'owner'));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.star_rounded);
      expect(icon.color, Colors.amber);
    });

    testWidgets('renders blue shield for admin', (tester) async {
      await tester.pumpApp(const MemberRoleIcon(role: 'admin'));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.shield_rounded);
      expect(icon.color, Colors.blue);
    });

    testWidgets('renders nothing for ordinary members', (tester) async {
      await tester.pumpApp(const MemberRoleIcon(role: 'member'));
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('renders nothing for null role', (tester) async {
      await tester.pumpApp(const MemberRoleIcon(role: null));
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('MemberRoleBadge', () {
    testWidgets('shows "Owner" label for owner role', (tester) async {
      await tester.pumpApp(const MemberRoleBadge(role: 'owner'));
      expect(find.text('Owner'), findsOneWidget);
    });

    testWidgets('shows "Admin" label for admin role', (tester) async {
      await tester.pumpApp(const MemberRoleBadge(role: 'admin'));
      expect(find.text('Admin'), findsOneWidget);
    });

    testWidgets('renders nothing for ordinary members', (tester) async {
      await tester.pumpApp(const MemberRoleBadge(role: 'member'));
      expect(find.text('Owner'), findsNothing);
      expect(find.text('Admin'), findsNothing);
    });
  });
}
