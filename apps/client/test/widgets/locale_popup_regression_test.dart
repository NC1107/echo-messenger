import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/locale_provider.dart';

/// Regression test for issues #736 / #741.
///
/// Without `GlobalMaterialLocalizations.delegate` in the app's
/// `localizationsDelegates`, `PopupMenuButton` (and other Material widgets)
/// crash under non-English locales because they dereference
/// `MaterialLocalizations.of(context)!`, which returns `null` when only the
/// default English fallback is registered.
///
/// This test mirrors the production `MaterialApp` configuration and verifies
/// that opening a `PopupMenuButton` under `Locale('fr')` does not throw.
Widget _harness(Locale locale) {
  return MaterialApp(
    locale: locale,
    supportedLocales: supportedFlutterLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: PopupMenuButton<String>(
          itemBuilder: (_) => const [
            PopupMenuItem<String>(value: 'a', child: Text('A')),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('PopupMenuButton opens under fr locale without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const Locale('fr')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PopupMenuItem<String>), findsWidgets);
  });

  testWidgets('PopupMenuButton opens under en baseline (sanity)', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const Locale('en')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PopupMenuItem<String>), findsWidgets);
  });
}
