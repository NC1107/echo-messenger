import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/theme_provider.dart';

/// AppearanceSection uses theme preview images that are unavailable in test.
/// Test the underlying state instead.
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
}
