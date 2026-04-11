import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/accessibility_provider.dart';

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

  group('AccessibilityNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('loads defaults from empty SharedPreferences', () async {
      final notifier = AccessibilityNotifier();
      // Allow async _load() to complete.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifier.state.fontScale, 1.0);
      expect(notifier.state.reducedMotion, isFalse);
      expect(notifier.state.highContrast, isFalse);
      notifier.dispose();
    });

    test('loads persisted values from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        kAccessibilityFontScale: 1.5,
        kAccessibilityReducedMotion: true,
        kAccessibilityHighContrast: true,
      });

      final notifier = AccessibilityNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifier.state.fontScale, 1.5);
      expect(notifier.state.reducedMotion, isTrue);
      expect(notifier.state.highContrast, isTrue);
      notifier.dispose();
    });

    test('setFontScale updates state and persists', () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = AccessibilityNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setFontScale(1.75);
      expect(notifier.state.fontScale, 1.75);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(kAccessibilityFontScale), 1.75);
      notifier.dispose();
    });

    test('setReducedMotion updates state and persists', () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = AccessibilityNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setReducedMotion(true);
      expect(notifier.state.reducedMotion, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAccessibilityReducedMotion), isTrue);
      notifier.dispose();
    });

    test('setHighContrast updates state and persists', () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = AccessibilityNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setHighContrast(true);
      expect(notifier.state.highContrast, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAccessibilityHighContrast), isTrue);
      notifier.dispose();
    });
  });
}
