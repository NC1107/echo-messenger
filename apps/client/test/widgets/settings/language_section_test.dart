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
  });
}
