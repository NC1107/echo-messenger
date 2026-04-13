import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/settings_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

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
    testWidgets('renders all navigation items', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: Scaffold(
              body: SizedBox(
                height: 600,
                child: SettingsNavList(
                  selected: SettingsSection.account,
                  onTap: (_) {},
                  onLogout: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check all sections are rendered
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: Scaffold(
              body: SizedBox(
                height: 600,
                child: SettingsNavList(onTap: (_) {}, onLogout: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('USER SETTINGS'), findsOneWidget);
      expect(find.text('APP SETTINGS'), findsOneWidget);
      expect(find.text('ADVANCED'), findsOneWidget);
    });

    testWidgets('renders Log Out button', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: Scaffold(
              body: SizedBox(
                height: 600,
                child: SettingsNavList(onTap: (_) {}, onLogout: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Log Out'), findsOneWidget);
    });

    testWidgets('tapping a section calls onTap', (tester) async {
      SettingsSection? tapped;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: Scaffold(
              body: SizedBox(
                height: 600,
                child: SettingsNavList(
                  onTap: (s) => tapped = s,
                  onLogout: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Privacy & Safety'));
      expect(tapped, SettingsSection.privacy);
    });

    testWidgets('tapping Log Out calls onLogout', (tester) async {
      var loggedOut = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: Scaffold(
              body: SizedBox(
                height: 600,
                child: SettingsNavList(
                  onTap: (_) {},
                  onLogout: () => loggedOut = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Log Out'));
      expect(loggedOut, isTrue);
    });
  });
}
