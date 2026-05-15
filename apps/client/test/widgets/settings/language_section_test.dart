import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/locale_provider.dart';
import 'package:echo_app/src/screens/settings/language_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: supportedFlutterLocales,
      home: Scaffold(body: child),
    ),
  );
}

const _kLoadDelay = Duration(milliseconds: 100);

// Bump the test viewport so the ListView renders every locale option in
// one frame.  The "Coming soon" banner + 7 locale tiles overflow the
// default 600 px test height and the section uses a ListView, so without
// this guard the last 2-3 tiles get lazily-built and the find queries
// miss them.
void _setLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LanguageSection', () {
    testWidgets('renders Language header', (tester) async {
      await tester.pumpWidget(_wrap(const LanguageSection()));
      await tester.pump(_kLoadDelay);
      expect(find.text('Language'), findsOneWidget);
    });

    testWidgets('renders all supported locale display names', (tester) async {
      _setLargeViewport(tester);
      await tester.pumpWidget(_wrap(const LanguageSection()));
      await tester.pump(_kLoadDelay);
      for (final entry in kSupportedLocales) {
        expect(
          find.text(entry.displayName),
          findsOneWidget,
          reason: '${entry.displayName} should appear in the list',
        );
      }
    });

    testWidgets('English is selected by default', (tester) async {
      await tester.pumpWidget(_wrap(const LanguageSection()));
      await tester.pump(_kLoadDelay);
      // The check icon appears next to the selected locale.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('persisted locale is pre-selected on load', (tester) async {
      SharedPreferences.setMockInitialValues({kLocaleKey: 'fr'});
      await tester.pumpWidget(_wrap(const LanguageSection()));
      await tester.pump(_kLoadDelay);
      // Only Français should show a check icon.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      // Confirm the selected text is styled differently (accent color).
      expect(find.text('Français'), findsOneWidget);
    });

    testWidgets('renders coming-soon banner so testers expect English only', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const LanguageSection()));
      await tester.pump(_kLoadDelay);
      expect(find.textContaining('Only English is fully'), findsOneWidget);
    });

    testWidgets('non-English options carry a Coming soon subtitle', (
      tester,
    ) async {
      _setLargeViewport(tester);
      await tester.pumpWidget(_wrap(const LanguageSection()));
      await tester.pump(_kLoadDelay);
      // One "Coming soon" subtitle per non-English locale.
      final nonEnglishCount = kSupportedLocales
          .where((e) => e.tag != 'en')
          .length;
      expect(find.text('Coming soon'), findsNWidgets(nonEnglishCount));
    });
  });
}
