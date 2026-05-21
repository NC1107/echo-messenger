import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/settings_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

const _adminAuthState = AuthState(
  isLoggedIn: true,
  userId: 'admin-user-id',
  username: 'opsy',
  token: 'fake-jwt-token',
  refreshToken: 'fake-refresh-token',
  isAdmin: true,
);

Widget _rootApp({
  SettingsSection? selected,
  void Function(SettingsSection)? onTap,
  VoidCallback? onLogout,
  AuthState authState = loggedInAuthState,
}) {
  return ProviderScope(
    overrides: [authOverride(authState), serverUrlOverride()],
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
      expect(settingsSectionLabel(SettingsSection.status), 'Status');
      expect(settingsSectionLabel(SettingsSection.appearance), 'Appearance');
      expect(settingsSectionLabel(SettingsSection.language), 'Language');
      expect(
        settingsSectionLabel(SettingsSection.notifications),
        'Notifications',
      );
      expect(settingsSectionLabel(SettingsSection.voiceVideo), 'Voice & Video');
      expect(settingsSectionLabel(SettingsSection.privacy), 'Privacy');
      expect(settingsSectionLabel(SettingsSection.devices), 'Devices');
      expect(settingsSectionLabel(SettingsSection.dataStorage), 'Storage');
      expect(
        settingsSectionLabel(SettingsSection.accessibility),
        'Accessibility',
      );
      expect(settingsSectionLabel(SettingsSection.about), 'About');
    });
  });

  group('SettingsSection enum', () {
    test('contains expected sections', () {
      expect(SettingsSection.values, hasLength(11));
      expect(
        SettingsSection.values,
        containsAll([
          SettingsSection.profile,
          SettingsSection.status,
          SettingsSection.appearance,
          SettingsSection.language,
          SettingsSection.notifications,
          SettingsSection.voiceVideo,
          SettingsSection.privacy,
          SettingsSection.devices,
          SettingsSection.dataStorage,
          SettingsSection.accessibility,
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

      // Profile is reached via the UserHeaderCard at the top, not a row.
      // Encryption keys is gone (was redundant with Privacy).
      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Voice & Video'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('renders group headers', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_rootApp());
      await tester.pumpAndSettle();

      expect(find.text('Account preferences'), findsOneWidget);
      expect(find.text('Echo'), findsOneWidget);
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

    testWidgets('hides admin dashboard tile for non-admin users', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_rootApp());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings-admin-dashboard-tile')),
        findsNothing,
      );
      expect(find.text('Admin dashboard'), findsNothing);
    });

    testWidgets('shows admin dashboard tile for admin users', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_rootApp(authState: _adminAuthState));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings-admin-dashboard-tile')),
        findsOneWidget,
      );
      expect(find.text('Admin dashboard'), findsOneWidget);
    });
  });
}
