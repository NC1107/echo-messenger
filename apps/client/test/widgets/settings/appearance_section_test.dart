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
          AppThemeSelection.dark,
          AppThemeSelection.light,
          AppThemeSelection.graphite,
          AppThemeSelection.ember,
          AppThemeSelection.neon,
          AppThemeSelection.sakura,
          AppThemeSelection.aurora,
        ]),
      );
    });

    test('has 8 theme options', () {
      expect(AppThemeSelection.values, hasLength(8));
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
