import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/theme_provider.dart';

/// Allow the build()-fired async _load() to settle.
Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  group('UIDensityNotifier', () {
    test(
      'build returns compact synchronously (today\'s effective default)',
      () {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        addTearDown(container.dispose);
        // Read before _load completes — the synchronous build() return value
        // must match today's effective default so brand-new users see no
        // behavior change while prefs are loading.
        final initial = container.read(uiDensityProvider);
        expect(initial, UIDensity.compact);
      },
    );

    test('loads compact when no prefs are set (no regression)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(uiDensityProvider);
      await _flushLoad();
      expect(container.read(uiDensityProvider), UIDensity.compact);
    });

    test(
      'migrates legacy MessageLayout=compact to UIDensity.compact',
      () async {
        SharedPreferences.setMockInitialValues({
          'echo_message_layout': 'compact',
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(uiDensityProvider);
        await _flushLoad();
        expect(container.read(uiDensityProvider), UIDensity.compact);
      },
    );

    test('migrates legacy MessageLayout=bubbles to UIDensity.normal', () async {
      SharedPreferences.setMockInitialValues({
        'echo_message_layout': 'bubbles',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(uiDensityProvider);
      await _flushLoad();
      expect(container.read(uiDensityProvider), UIDensity.normal);
    });

    test('migrates legacy MessageLayout=plain to UIDensity.normal', () async {
      SharedPreferences.setMockInitialValues({'echo_message_layout': 'plain'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(uiDensityProvider);
      await _flushLoad();
      expect(container.read(uiDensityProvider), UIDensity.normal);
    });

    test('reads echo_ui_density when present (cozy)', () async {
      SharedPreferences.setMockInitialValues({'echo_ui_density': 'cozy'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(uiDensityProvider);
      await _flushLoad();
      expect(container.read(uiDensityProvider), UIDensity.cozy);
    });

    test('reads echo_ui_density when present (normal)', () async {
      SharedPreferences.setMockInitialValues({'echo_ui_density': 'normal'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(uiDensityProvider);
      await _flushLoad();
      expect(container.read(uiDensityProvider), UIDensity.normal);
    });

    test(
      'explicit echo_ui_density overrides legacy MessageLayout migration',
      () async {
        // Once the user picks a density, that wins regardless of the legacy
        // MessageLayout value.
        SharedPreferences.setMockInitialValues({
          'echo_ui_density': 'cozy',
          'echo_message_layout': 'compact',
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(uiDensityProvider);
        await _flushLoad();
        expect(container.read(uiDensityProvider), UIDensity.cozy);
      },
    );

    test('setDensity updates state and persists round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(uiDensityProvider);
      await _flushLoad();

      await container
          .read(uiDensityProvider.notifier)
          .setDensity(UIDensity.cozy);

      expect(container.read(uiDensityProvider), UIDensity.cozy);

      // Verify persistence: a fresh container reads the saved value.
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      container2.read(uiDensityProvider);
      await _flushLoad();
      expect(container2.read(uiDensityProvider), UIDensity.cozy);
    });

    test('unknown saved value falls back to normal', () async {
      SharedPreferences.setMockInitialValues({'echo_ui_density': 'roomy'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(uiDensityProvider);
      await _flushLoad();
      expect(container.read(uiDensityProvider), UIDensity.normal);
    });
  });
}
