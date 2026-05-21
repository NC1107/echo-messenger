import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/settings/notification_section.dart';
import 'package:echo_app/src/services/sound_service.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

// SharedPreferences keys (kept in sync with the constants in
// notification_section.dart).
const _kNotificationsEnabled = 'notifications_enabled';
const _kDmNotifications = 'dm_notifications_enabled';
const _kGroupNotifications = 'group_notifications_enabled';
const _kDndEnabled = 'dnd_enabled';
const _kQuietHoursEnabled = 'quiet_hours_enabled';
const _kQuietHoursStart = 'quiet_hours_start';
const _kQuietHoursEnd = 'quiet_hours_end';

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

    testWidgets('renders Do Not Disturb toggle', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Do Not Disturb'), findsOneWidget);
    });

    testWidgets('renders Quiet Hours toggle', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Quiet Hours'), findsOneWidget);
    });

    testWidgets('renders message sound selector', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // Voice & Video subpage entry was added at top, pushing the message
      // sound selector off-screen. Use skipOffstage: false to find it.
      expect(find.text('Message Sound', skipOffstage: false), findsOneWidget);
    });

    testWidgets('shows sub-toggles when notifications enabled', (tester) async {
      SharedPreferences.setMockInitialValues({_kNotificationsEnabled: true});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Direct Messages'), findsOneWidget);
      expect(find.text('Group Messages'), findsOneWidget);
    });

    testWidgets('hides sub-toggles when notifications disabled', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_kNotificationsEnabled: false});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Direct Messages'), findsNothing);
      expect(find.text('Group Messages'), findsNothing);
    });

    testWidgets('shows test notification button', (tester) async {
      SharedPreferences.setMockInitialValues({_kNotificationsEnabled: true});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // DND + quiet hours sections push the button off-screen.
      expect(
        find.text('Send Test Notification', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('shows DND banner when Do Not Disturb is enabled', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_kDndEnabled: true});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.textContaining('Do Not Disturb is on'), findsOneWidget);
    });

    testWidgets('hides DND banner when Do Not Disturb is disabled', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_kDndEnabled: false});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.textContaining('Do Not Disturb is on'), findsNothing);
    });

    testWidgets('toggling DND off persists to SharedPreferences', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_kDndEnabled: true});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // Tap the DND switch — the tile title is unique so we can locate it
      // through its ancestor SwitchListTile.
      final dndSwitch = find.ancestor(
        of: find.text('Do Not Disturb'),
        matching: find.byType(SwitchListTile),
      );
      expect(dndSwitch, findsOneWidget);
      await tester.tap(dndSwitch);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_kDndEnabled), isFalse);
    });

    testWidgets('enabling Quiet Hours reveals start/end time tiles', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_kQuietHoursEnabled: true});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Start time'), findsOneWidget);
      expect(find.text('End time'), findsOneWidget);
    });

    testWidgets('Quiet Hours tiles hidden when toggle is off', (tester) async {
      SharedPreferences.setMockInitialValues({_kQuietHoursEnabled: false});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Start time'), findsNothing);
      expect(find.text('End time'), findsNothing);
    });

    testWidgets('time tiles render formatted persisted quiet hour times', (
      tester,
    ) async {
      // Use 09:00 / 17:30 to avoid ambiguity across 12h/24h locales —
      // we'll assert the digits are present somewhere in the rendered tile
      // rather than pinning to a specific format string.
      SharedPreferences.setMockInitialValues({
        _kQuietHoursEnabled: true,
        _kQuietHoursStart: '09:00',
        _kQuietHoursEnd: '17:30',
      });
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // Either 24h "09:00" or 12h "9:00 AM" — match the leading hour digit.
      expect(
        find.textContaining(RegExp(r'9:00')),
        findsOneWidget,
        reason: 'start time tile should render 09:00 in some locale form',
      );
      expect(
        find.textContaining(RegExp(r'5:30')),
        findsOneWidget,
        reason: 'end time tile should render 17:30 in some locale form',
      );
    });

    testWidgets('tapping a quiet-hours tile opens the time picker dialog', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_kQuietHoursEnabled: true});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start time'));
      await tester.pumpAndSettle();

      // Dialog should display the supplied helpText.
      expect(find.text('Quiet Hours Start'), findsOneWidget);

      // Dismiss the dialog so the tree can tear down cleanly.
      final cancel = find.text('Cancel');
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel.first);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('sound dropdown lists all NotificationSound options', (
      tester,
    ) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      final dropdown = find.byType(
        DropdownButton<NotificationSound>,
        skipOffstage: false,
      );
      expect(dropdown, findsOneWidget);

      // Scroll the dropdown into view before tapping it.
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();

      // The menu shows one item per enum value (plus the currently-selected
      // item rendered in the field). findsWidgets allows for that.
      for (final sound in NotificationSound.values) {
        expect(
          find.text(sound.label),
          findsWidgets,
          reason: '${sound.label} should appear in the dropdown menu',
        );
      }

      // Close the menu so the widget tree can settle.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    });

    testWidgets('toggling Enable Notifications persists the new value', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_kNotificationsEnabled: true});
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      final enableSwitch = find.ancestor(
        of: find.text('Enable Notifications'),
        matching: find.byType(SwitchListTile),
      );
      await tester.ensureVisible(enableSwitch);
      await tester.pumpAndSettle();
      await tester.tap(enableSwitch);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_kNotificationsEnabled), isFalse);
      // Children should now be hidden.
      expect(find.text('Direct Messages'), findsNothing);
      expect(find.text('Group Messages'), findsNothing);
    });

    testWidgets('toggling Direct Messages persists to SharedPreferences', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        _kNotificationsEnabled: true,
        _kDmNotifications: true,
        _kGroupNotifications: true,
      });
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      final dmSwitch = find.ancestor(
        of: find.text('Direct Messages'),
        matching: find.byType(SwitchListTile),
      );
      await tester.ensureVisible(dmSwitch);
      await tester.pumpAndSettle();
      await tester.tap(dmSwitch);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_kDmNotifications), isFalse);
      // The Group Messages preference must stay untouched.
      expect(prefs.getBool(_kGroupNotifications), isTrue);
    });

    testWidgets('toggling Quiet Hours persists to SharedPreferences', (
      tester,
    ) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      final quietSwitch = find.ancestor(
        of: find.text('Quiet Hours'),
        matching: find.byType(SwitchListTile),
      );
      await tester.tap(quietSwitch);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_kQuietHoursEnabled), isTrue);
      // The time tiles should now be visible.
      expect(find.text('Start time'), findsOneWidget);
      expect(find.text('End time'), findsOneWidget);
    });
  });
}
