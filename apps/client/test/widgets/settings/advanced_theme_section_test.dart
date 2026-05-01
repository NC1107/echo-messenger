import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/theme_provider.dart';
import 'package:echo_app/src/screens/settings/advanced_theme_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

Widget _wrap(Widget child, {CustomColorsState? initialColors}) {
  SharedPreferences.setMockInitialValues({});
  return ProviderScope(
    overrides: [
      if (initialColors != null)
        customColorsProvider.overrideWith(() {
          return _FakeCustomColors(initialColors);
        }),
    ],
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      home: Scaffold(body: child),
    ),
  );
}

/// Fake notifier so we can seed state without hitting SharedPreferences.
class _FakeCustomColors extends CustomColors {
  final CustomColorsState _initial;
  _FakeCustomColors(this._initial);

  @override
  CustomColorsState build() => _initial;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AdvancedThemeInline', () {
    testWidgets('renders primary and accent color tiles', (tester) async {
      await tester.pumpWidget(_wrap(const AdvancedThemeInline()));
      await tester.pump();

      expect(find.text('Primary color'), findsOneWidget);
      expect(find.text('Accent color'), findsOneWidget);
    });

    testWidgets('does not show reset button when no overrides', (tester) async {
      await tester.pumpWidget(_wrap(const AdvancedThemeInline()));
      await tester.pump();

      expect(find.text('Reset to theme defaults'), findsNothing);
    });

    testWidgets('shows reset button when primary override is set', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const AdvancedThemeInline(),
          initialColors: const CustomColorsState(
            primaryColor: Color(0xFFFF0000),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Reset to theme defaults'), findsOneWidget);
      expect(find.byKey(const Key('reset_colors_button')), findsOneWidget);
    });

    testWidgets('shows custom badge on overridden tiles', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const AdvancedThemeInline(),
          initialColors: const CustomColorsState(
            accentColor: Color(0xFF0000FF),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('custom'), findsOneWidget);
    });

    testWidgets('picker tiles have accessibility semantics', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(const AdvancedThemeInline()));
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('Primary color picker')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Accent color picker')),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}
