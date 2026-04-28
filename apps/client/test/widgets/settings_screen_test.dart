import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/settings_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

Widget _rootApp({
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
        body: SettingsRootView(
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
      expect(settingsSectionLabel(SettingsSection.profile), 'Profile');
      expect(
        settingsSectionLabel(SettingsSection.encryptionKeys),
        'Encryption keys',
      );
      expect(settingsSectionLabel(SettingsSection.devices), 'Devices');
      expect(settingsSectionLabel(SettingsSection.appearance), 'Appearance');
      expect(
        settingsSectionLabel(SettingsSection.notifications),
        'Notifications',
      );
      expect(settingsSectionLabel(SettingsSection.privacy), 'Privacy');
      expect(settingsSectionLabel(SettingsSection.dataStorage), 'Storage');
      expect(settingsSectionLabel(SettingsSection.about), 'About');
    });
  });

  group('SettingsSection enum', () {
    test('contains expected 8 sections', () {
      expect(SettingsSection.values, hasLength(8));
      expect(
        SettingsSection.values,
        containsAll([
          SettingsSection.profile,
          SettingsSection.encryptionKeys,
          SettingsSection.devices,
          SettingsSection.appearance,
          SettingsSection.notifications,
          SettingsSection.privacy,
          SettingsSection.dataStorage,
          SettingsSection.about,
        ]),
      );
    });
  });

  group('SettingsRootView', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    testWidgets('renders all navigation rows', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_rootApp(selected: SettingsSection.profile));
      await tester.pumpAndSettle();

      // Profile is reached via the UserHeaderCard at the top, not a duplicate
      // row in the Account group.
      expect(find.text('Encryption keys'), findsOneWidget);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('renders the 3 group headers', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_rootApp());
      await tester.pumpAndSettle();

      expect(find.text('ACCOUNT'), findsOneWidget);
      expect(find.text('PREFERENCES'), findsOneWidget);
      expect(find.text('ECHO'), findsOneWidget);
    });

    testWidgets('renders Log out button', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_rootApp());
      await tester.pumpAndSettle();

      expect(find.text('Log out'), findsOneWidget);
    });

    testWidgets('tapping a section calls onTap', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SettingsSection? tapped;
      await tester.pumpWidget(_rootApp(onTap: (s) => tapped = s));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Privacy'));
      expect(tapped, SettingsSection.privacy);
    });

    testWidgets('tapping Log out calls onLogout', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var loggedOut = false;
      await tester.pumpWidget(_rootApp(onLogout: () => loggedOut = true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Log out'));
      expect(loggedOut, isTrue);
    });
  });
}
