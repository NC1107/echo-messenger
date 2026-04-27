import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/settings/notification_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildSection() {
    return MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const Scaffold(body: NotificationSection()),
    );
  }

  group('NotificationSection', () {
    testWidgets('renders section title', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsOneWidget);
    });

    testWidgets('renders enable notifications toggle', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Enable Notifications'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    });

    testWidgets('renders message sound selector', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // Voice & Video subpage entry was added at top, pushing the message
      // sound selector off-screen. Use skipOffstage: false to find it.
      expect(find.text('Message Sound', skipOffstage: false), findsOneWidget);
    });

    testWidgets('shows sub-toggles when notifications enabled', (tester) async {
      SharedPreferences.setMockInitialValues({
        'echo_notifications_enabled': true,
      });
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Direct Messages'), findsOneWidget);
      expect(find.text('Group Messages'), findsOneWidget);
    });

    testWidgets('shows test notification button', (tester) async {
      SharedPreferences.setMockInitialValues({
        'echo_notifications_enabled': true,
      });
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // DND + quiet hours sections push the button off-screen.
      expect(
        find.text('Send Test Notification', skipOffstage: false),
        findsOneWidget,
      );
    });
  });
}
