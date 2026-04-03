import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';

/// Pumps a [widget] wrapped in the minimal MaterialApp + ProviderScope shell
/// needed to render Echo widgets in tests.
///
/// [overrides] lets callers replace Riverpod providers with test doubles.
/// The dark theme (with EchoColorExtension) is applied so that BuildContext
/// extensions like `context.textMuted` resolve without errors.
extension PumpApp on WidgetTester {
  /// Pump a widget inside a themed MaterialApp with Riverpod overrides.
  Future<void> pumpApp(
    Widget widget, {
    List<Override> overrides = const [],
    NavigatorObserver? navigatorObserver,
  }) async {
    await pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          navigatorObservers: navigatorObserver != null
              ? [navigatorObserver]
              : [],
          home: Scaffold(body: widget),
        ),
      ),
    );
  }

  /// Pump a screen-level widget (no extra Scaffold wrapper).
  Future<void> pumpScreen(
    Widget screen, {
    List<Override> overrides = const [],
  }) async {
    await pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: screen,
        ),
      ),
    );
  }
}
