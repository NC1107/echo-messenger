import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/settings/card_row.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: EchoTheme.darkTheme,
    darkTheme: EchoTheme.darkTheme,
    themeMode: ThemeMode.dark,
    home: Scaffold(body: child),
  );
}

void main() {
  group('CardRow', () {
    testWidgets('renders icon, label, trailing value, and chevron', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          CardRow(
            icon: Icons.palette_outlined,
            iconColor: const Color(0xFF8458E9),
            label: 'Appearance',
            trailingValue: 'Dark',
            onTap: () {},
          ),
        ),
      );

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('fires onTap when tapped', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          CardRow(
            icon: Icons.person_outlined,
            iconColor: const Color(0xFF5557E0),
            label: 'Profile',
            onTap: () => taps += 1,
          ),
        ),
      );

      await tester.tap(find.text('Profile'));
      expect(taps, 1);
    });

    testWidgets(
      'destructive variant suppresses chevron and uses danger color',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            CardRow(
              icon: Icons.logout,
              iconColor: EchoTheme.danger,
              label: 'Log out',
              destructive: true,
              trailingValue: 'should be hidden',
              onTap: () {},
            ),
          ),
        );

        expect(find.text('Log out'), findsOneWidget);
        // Chevron suppressed for destructive rows.
        expect(find.byIcon(Icons.chevron_right), findsNothing);
        // Trailing value suppressed for destructive rows.
        expect(find.text('should be hidden'), findsNothing);

        // Label should render in the danger color.
        final textWidget = tester.widget<Text>(find.text('Log out'));
        expect(textWidget.style?.color, EchoTheme.danger);
      },
    );

    testWidgets('renders disabled when onTap is null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const CardRow(
            icon: Icons.info_outline,
            iconColor: Colors.white,
            label: 'About',
            trailingValue: 'v1.0',
          ),
        ),
      );

      // Still rendered, just dimmed.
      expect(find.text('About'), findsOneWidget);
      expect(find.byType(Opacity), findsWidgets);
    });
  });
}
