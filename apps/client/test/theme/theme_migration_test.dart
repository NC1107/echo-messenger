import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/theme_provider.dart';

/// Pump enough microtasks for the build()-fired _load() to settle.
Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

/// Asserts every row of the persisted-theme migration table:
///   - the legacy stored string resolves to the new enum value
///   - after load, the canonical new name is written back to prefs so the
///     migration path is one-shot (palette-reduction-2026-05-11).
void main() {
  group('AppTheme legacy-string migration', () {
    const cases = <String, AppThemeSelection>{
      // No-op (canonical names already in the new set).
      'system': AppThemeSelection.system,
      'indigo': AppThemeSelection.indigo,
      'paper': AppThemeSelection.paper,
      'graphite': AppThemeSelection.graphite,
      'ember': AppThemeSelection.ember,
      'sakura': AppThemeSelection.sakura,
      'highContrast': AppThemeSelection.highContrast,
      // Renames.
      'dark': AppThemeSelection.indigo,
      'light': AppThemeSelection.paper,
      // Cut themes -> substitute.
      'aurora': AppThemeSelection.indigo,
      'neon': AppThemeSelection.highContrast,
      // Collapsed HC variants.
      'highContrastDark': AppThemeSelection.highContrast,
      'highContrastLight': AppThemeSelection.paper,
    };

    for (final entry in cases.entries) {
      test('legacy "${entry.key}" migrates to ${entry.value.name}', () async {
        SharedPreferences.setMockInitialValues({'echo_theme_mode': entry.key});
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(appThemeProvider);
        await _flushLoad();

        // 1. Enum state matches the migration target.
        expect(
          container.read(appThemeProvider),
          entry.value,
          reason: '"${entry.key}" should resolve to ${entry.value.name}',
        );

        // 2. The canonical new name is written back to prefs so subsequent
        //    loads skip the migration path.
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('echo_theme_mode'),
          entry.value.name,
          reason:
              '"${entry.key}" should normalize to "${entry.value.name}" in prefs',
        );
      });
    }

    test('unknown value falls back to indigo and is written back', () async {
      SharedPreferences.setMockInitialValues({
        'echo_theme_mode': 'definitely-not-a-theme',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeProvider);
      await _flushLoad();

      expect(container.read(appThemeProvider), AppThemeSelection.indigo);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_theme_mode'), 'indigo');
    });

    test('null prefs value falls back to indigo and is written back', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeProvider);
      await _flushLoad();

      expect(container.read(appThemeProvider), AppThemeSelection.indigo);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_theme_mode'), 'indigo');
    });
  });
}
