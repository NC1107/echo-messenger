import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/accessibility_provider.dart';

/// Pump enough microtasks for the build()-fired _load() to settle.
Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  group('AccessibilityState', () {
    test('default state has standard values', () {
      const state = AccessibilityState();
      expect(state.fontScale, 1.0);
      expect(state.reducedMotion, isFalse);
      expect(state.highContrast, isFalse);
    });

    test('copyWith preserves unchanged fields', () {
      const state = AccessibilityState(
        fontScale: 1.5,
        reducedMotion: true,
        highContrast: true,
      );
      final copied = state.copyWith(fontScale: 2.0);
      expect(copied.fontScale, 2.0);
      expect(copied.reducedMotion, isTrue);
      expect(copied.highContrast, isTrue);
    });

    test('copyWith sets individual fields', () {
      const state = AccessibilityState();
      expect(state.copyWith(fontScale: 1.25).fontScale, 1.25);
      expect(state.copyWith(reducedMotion: true).reducedMotion, isTrue);
      expect(state.copyWith(highContrast: true).highContrast, isTrue);
    });
  });

  group('Accessibility (Notifier)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('loads defaults from empty SharedPreferences', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(accessibilityProvider);
      expect(state.fontScale, 1.0);
      expect(state.reducedMotion, isFalse);
      expect(state.highContrast, isFalse);
      // After _load() resolves, state stays at defaults (no persisted values).
      await _flushLoad();
      final after = container.read(accessibilityProvider);
      expect(after.fontScale, 1.0);
    });

    test('loads persisted values from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        kAccessibilityFontScale: 1.5,
        kAccessibilityReducedMotion: true,
        kAccessibilityHighContrast: true,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Trigger build().
      container.read(accessibilityProvider);
      await _flushLoad();

      final after = container.read(accessibilityProvider);
      expect(after.fontScale, 1.5);
      expect(after.reducedMotion, isTrue);
      expect(after.highContrast, isTrue);
    });

    test('setFontScale updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(accessibilityProvider);
      await _flushLoad();

      await container.read(accessibilityProvider.notifier).setFontScale(1.75);
      expect(container.read(accessibilityProvider).fontScale, 1.75);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(kAccessibilityFontScale), 1.75);
    });

    test('setReducedMotion updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(accessibilityProvider);
      await _flushLoad();

      await container
          .read(accessibilityProvider.notifier)
          .setReducedMotion(true);
      expect(container.read(accessibilityProvider).reducedMotion, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAccessibilityReducedMotion), isTrue);
    });

    test('setHighContrast updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(accessibilityProvider);
      await _flushLoad();

      await container
          .read(accessibilityProvider.notifier)
          .setHighContrast(true);
      expect(container.read(accessibilityProvider).highContrast, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAccessibilityHighContrast), isTrue);
    });
  });
}
