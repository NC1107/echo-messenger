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

    testWidgets('renders GIF autoplay toggle (#1137)', (tester) async {
      await _pump(tester);
      // GIF autoplay moved from Appearance → Accessibility in #1137 because
      // autoplay is a motion / vestibular / distraction concern.
      expect(find.text('Auto-play GIFs'), findsOneWidget);
    });

    testWidgets('renders High Contrast switch', (tester) async {
      await _pump(tester);
      expect(find.text('High Contrast'), findsOneWidget);
    });

    testWidgets('Font Size slider is NOT here — moved to Appearance (#1137)', (
      tester,
    ) async {
      await _pump(tester);
      // Font size is a visual preference; it lives in Appearance now.
      expect(find.text('Font Size'), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('Reduce Motion + High Contrast + GIF autoplay all present', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('Reduce Motion'), findsOneWidget);
      expect(find.text('High Contrast'), findsOneWidget);
      expect(find.text('Auto-play GIFs'), findsOneWidget);
    });
  });
}
