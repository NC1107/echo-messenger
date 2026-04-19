import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/settings_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

Widget _navListApp({
  SettingsSection? selected,
  void Function(SettingsSection)? onTap,
  VoidCallback? onLogout,
}) {
  return ProviderScope(
    overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: SettingsNavList(
          selected: selected,
          onTap: onTap ?? (_) {},
          onLogout: onLogout ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  group('settingsSectionLabel', () {
    test('returns correct label for each section', () {
      expect(settingsSectionLabel(SettingsSection.account), 'Account');
      expect(settingsSectionLabel(SettingsSection.devices), 'My Devices');
      expect(settingsSectionLabel(SettingsSection.privacy), 'Privacy & Safety');
      expect(
        settingsSectionLabel(SettingsSection.notifications),
        'Notifications',
      );
      expect(settingsSectionLabel(SettingsSection.audio), 'Voice & Video');
      expect(settingsSectionLabel(SettingsSection.appearance), 'Appearance');
      expect(
        settingsSectionLabel(SettingsSection.accessibility),
        'Accessibility',
      );
      expect(settingsSectionLabel(SettingsSection.about), 'About');
      expect(
        settingsSectionLabel(SettingsSection.dataStorage),
        'Data & Storage',
      );
      expect(settingsSectionLabel(SettingsSection.debug), 'Debug Logs');
    });
  });

  group('SettingsSection enum', () {
    test('contains all expected sections', () {
      expect(SettingsSection.values, hasLength(10));
      expect(
        SettingsSection.values,
        containsAll([
          SettingsSection.account,
          SettingsSection.devices,
          SettingsSection.privacy,
          SettingsSection.notifications,
          SettingsSection.audio,
          SettingsSection.appearance,
          SettingsSection.accessibility,
          SettingsSection.about,
          SettingsSection.dataStorage,
          SettingsSection.debug,
        ]),
      );
    });
  });

  group('SettingsNavList', () {
    // The nav list needs ~700px of height to avoid overflow with all sections
    // plus the Log Out item at the bottom. Set a tall viewport for all tests.
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    testWidgets('renders all navigation items', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_navListApp(selected: SettingsSection.account));
      await tester.pumpAndSettle();

      expect(find.text('Account'), findsOneWidget);
      expect(find.text('My Devices'), findsOneWidget);
      expect(find.text('Privacy & Safety'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Voice & Video'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Accessibility'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.text('Data & Storage'), findsOneWidget);
      expect(find.text('Debug Logs'), findsOneWidget);
    });

    testWidgets('renders category headers', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_navListApp());
      await tester.pumpAndSettle();

      expect(find.text('USER SETTINGS'), findsOneWidget);
      expect(find.text('APP SETTINGS'), findsOneWidget);
      expect(find.text('ADVANCED'), findsOneWidget);
    });

    testWidgets('renders Log Out button', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_navListApp());
      await tester.pumpAndSettle();

      expect(find.text('Log Out'), findsOneWidget);
    });

    testWidgets('tapping a section calls onTap', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SettingsSection? tapped;
      await tester.pumpWidget(_navListApp(onTap: (s) => tapped = s));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Privacy & Safety'));
      expect(tapped, SettingsSection.privacy);
    });

    testWidgets('tapping Log Out calls onLogout', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var loggedOut = false;
      await tester.pumpWidget(_navListApp(onLogout: () => loggedOut = true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Log Out'));
      expect(loggedOut, isTrue);
    });
  });
}
