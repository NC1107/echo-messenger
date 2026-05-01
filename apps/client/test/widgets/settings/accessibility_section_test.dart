import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/settings/accessibility_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

/// Pump [AccessibilitySection] inside a minimal [ProviderScope] + [MaterialApp].
Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(body: AccessibilitySection()),
      ),
    ),
  );
  // Allow async _load() to settle.
  await tester.pumpAndSettle();
}

void main() {
  group('AccessibilitySection', () {
    testWidgets('renders Reduce Motion switch', (tester) async {
      await _pump(tester);
      expect(find.text('Reduce Motion'), findsOneWidget);
    });

    testWidgets('renders Font Size slider', (tester) async {
      await _pump(tester);
      expect(find.text('Font Size'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('renders High Contrast switch', (tester) async {
      await _pump(tester);
      expect(find.text('High Contrast'), findsOneWidget);
    });

    testWidgets('all three controls are present', (tester) async {
      await _pump(tester);
      // Two SwitchListTile.adaptive widgets (reduce motion + high contrast)
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('Reduce Motion'), findsOneWidget);
      expect(find.text('High Contrast'), findsOneWidget);
    });
  });
}
