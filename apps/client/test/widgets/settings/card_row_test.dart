import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/theme_provider.dart' show UIDensity;
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/settings/card_row.dart';

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

  // -------------------------------------------------------------
  // Phase 2 follow-up: settings row density tiers.
  // -------------------------------------------------------------

  group('CardRow density', () {
    Future<void> pumpAt(WidgetTester tester, UIDensity density) async {
      await tester.pumpWidget(
        _wrap(
          CardRow(
            icon: Icons.palette_outlined,
            iconColor: const Color(0xFF8458E9),
            label: 'Appearance',
            trailingValue: 'Dark',
            onTap: () {},
            density: density,
          ),
        ),
      );
    }

    testWidgets('cozy renders 16pt label and 64px row', (tester) async {
      await pumpAt(tester, UIDensity.cozy);
      final label = tester.widget<Text>(find.text('Appearance'));
      expect(label.style?.fontSize, 16);
      final row = tester.widget<SizedBox>(
        find
            .ancestor(
              of: find.byType(Material),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(row.height, 64);
    });

    testWidgets('normal renders 15pt label and 56px row', (tester) async {
      await pumpAt(tester, UIDensity.normal);
      final label = tester.widget<Text>(find.text('Appearance'));
      expect(label.style?.fontSize, 15);
      final row = tester.widget<SizedBox>(
        find
            .ancestor(
              of: find.byType(Material),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(row.height, 56);
    });

    testWidgets('compact renders 13pt label and 44px row', (tester) async {
      await pumpAt(tester, UIDensity.compact);
      final label = tester.widget<Text>(find.text('Appearance'));
      expect(label.style?.fontSize, 13);
      final row = tester.widget<SizedBox>(
        find
            .ancestor(
              of: find.byType(Material),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(row.height, 44);
    });
  });
}
