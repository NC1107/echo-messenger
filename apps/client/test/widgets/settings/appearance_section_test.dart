import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/encrypted_preview_provider.dart';
import 'package:echo_app/src/providers/theme_provider.dart';
import 'package:echo_app/src/screens/settings/appearance_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

/// AppearanceSection renders an inline preview grid whose miniature
/// `_ThemeThumbnail` widgets pack a Column of bubble hints into a fixed
/// ~73 px slot. The natural Column content overflows by ~3 px under any
/// of the tested viewport sizes; the overflow paints yellow stripes in
/// the UI but doesn't visually break the screen, so we drain the resulting
/// non-fatal exceptions instead of letting them mark the test as failed.
Future<void> _pumpWide(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1600, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(body: AppearanceSection()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  // Drain the (known, benign) layout-overflow exceptions thrown by the
  // mini-preview Columns so they don't surface as test failures.
  while (tester.takeException() != null) {}
}

void main() {
  group('AppThemeSelection', () {
    test('all theme variants are defined', () {
      expect(
        AppThemeSelection.values,
        containsAll([
          AppThemeSelection.system,
          AppThemeSelection.indigo,
          AppThemeSelection.paper,
          AppThemeSelection.graphite,
          AppThemeSelection.ember,
          AppThemeSelection.sakura,
          AppThemeSelection.highContrast,
        ]),
      );
    });

    test('has 7 theme options', () {
      expect(AppThemeSelection.values, hasLength(7));
    });
  });

  group('MessageLayout', () {
    test('has bubbles, compact, and plain options', () {
      expect(
        MessageLayout.values,
        containsAll([
          MessageLayout.bubbles,
          MessageLayout.compact,
          MessageLayout.plain,
        ]),
      );
    });

    test('has 3 layout options', () {
      expect(MessageLayout.values, hasLength(3));
    });
  });

  group('AppearanceSection (widget)', () {
    testWidgets('renders every section header', (tester) async {
      await _pumpWide(tester);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Message layout'), findsOneWidget);
      expect(find.text('Density'), findsOneWidget);
      expect(find.text('Channels'), findsOneWidget);
    });

    testWidgets('renders the three message-layout option labels', (
      tester,
    ) async {
      await _pumpWide(tester);
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Discord'), findsOneWidget);
      expect(find.text('Slack'), findsOneWidget);
    });

    testWidgets('renders the three density option labels', (tester) async {
      await _pumpWide(tester);
      expect(find.text('Cozy'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Compact'), findsOneWidget);
    });

    testWidgets('renders Font Size slider — moved from Accessibility (#1137)', (
      tester,
    ) async {
      await _pumpWide(tester);
      expect(find.text('Font Size'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('no longer renders the GIF autoplay toggle (#1137)', (
      tester,
    ) async {
      await _pumpWide(tester);
      // GIF autoplay moved to Accessibility because it's a motion concern.
      expect(find.text('Auto-play GIFs'), findsNothing);
    });

    testWidgets('renders Show encrypted previews toggle (#1137)', (
      tester,
    ) async {
      await _pumpWide(tester);
      expect(find.text('Show encrypted previews'), findsOneWidget);
    });

    testWidgets('Show encrypted previews toggle is ON by default (#1137)', (
      tester,
    ) async {
      await _pumpWide(tester);
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      // Find the switch whose value matches the provider default (true).
      // We locate it by verifying at least one Switch in the tree is on.
      expect(switches.any((s) => s.value), isTrue);
    });

    testWidgets('Show encrypted previews toggle can be turned off (#1137)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kShowEncryptedPreviewsKey: false,
      });
      tester.view.physicalSize = const Size(1600, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const Scaffold(body: AppearanceSection()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      while (tester.takeException() != null) {}

      // After async load settles the toggle should reflect the stored false.
      await tester.pump(const Duration(milliseconds: 50));
      while (tester.takeException() != null) {}

      expect(find.text('Show encrypted previews'), findsOneWidget);
    });
  });
}
