import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/settings/settings_list_tile.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('SettingsListTile', () {
    testWidgets('renders icon, title, and subtitle', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SettingsListTile(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            subtitle: 'All messages',
          ),
        ),
      );

      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('All messages'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    });

    testWidgets('chevron appears when onTap is non-null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SettingsListTile(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy',
            onTap: () {},
          ),
        ),
      );

      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('no chevron when onTap is null', (tester) async {
      await tester.pumpWidget(
        _wrap(const SettingsListTile(icon: Icons.info_outline, title: 'Info')),
      );

      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('destructive uses danger color on title', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SettingsListTile(
            icon: Icons.delete_outline,
            title: 'Delete Account',
            destructive: true,
            onTap: () {},
          ),
        ),
      );

      final titleWidget = tester.widget<Text>(find.text('Delete Account'));
      expect(titleWidget.style?.color, EchoTheme.danger);
    });

    testWidgets('destructive suppresses default chevron', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SettingsListTile(
            icon: Icons.delete_outline,
            title: 'Delete Account',
            destructive: true,
            onTap: () {},
          ),
        ),
      );

      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('custom trailing overrides default chevron', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SettingsListTile(
            icon: Icons.storage,
            title: 'Cache',
            trailing: const Text('24 MB'),
            onTap: () {},
          ),
        ),
      );

      expect(find.text('24 MB'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('leading widget takes precedence over icon', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SettingsListTile(
            leading: const CircleAvatar(key: Key('avatar'), radius: 16),
            icon: Icons.person_outline,
            title: 'Profile',
            onTap: () {},
          ),
        ),
      );

      expect(find.byKey(const Key('avatar')), findsOneWidget);
      // The icon is shadowed by leading; ListTile renders at most one leading.
      expect(find.byIcon(Icons.person_outline), findsNothing);
    });

    testWidgets('fires onTap callback when tapped', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          SettingsListTile(
            icon: Icons.language,
            title: 'Language',
            onTap: () => taps += 1,
          ),
        ),
      );

      await tester.tap(find.text('Language'));
      expect(taps, 1);
    });

    testWidgets('no leading when both icon and leading are null', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SettingsListTile(title: 'Plain row')),
      );

      expect(find.text('Plain row'), findsOneWidget);
      // No icon rendered for the leading area.
      expect(find.byType(Icon), findsNothing);
    });
  });
}
