import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/theme_provider.dart';

/// Pump enough microtasks for the build()-fired _load() to settle.
Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  group('CustomColorsState', () {
    test('default state has no overrides', () {
      const state = CustomColorsState();
      expect(state.primaryColor, isNull);
      expect(state.accentColor, isNull);
      expect(state.hasOverrides, isFalse);
    });

    test('hasOverrides is true when primaryColor is set', () {
      const state = CustomColorsState(primaryColor: Colors.red);
      expect(state.hasOverrides, isTrue);
    });

    test('hasOverrides is true when accentColor is set', () {
      const state = CustomColorsState(accentColor: Colors.blue);
      expect(state.hasOverrides, isTrue);
    });

    test('copyWith sets primaryColor', () {
      const state = CustomColorsState();
      final updated = state.copyWith(primaryColor: Colors.green);
      expect(updated.primaryColor, Colors.green);
      expect(updated.accentColor, isNull);
    });

    test('copyWith sets accentColor', () {
      const state = CustomColorsState();
      final updated = state.copyWith(accentColor: Colors.orange);
      expect(updated.accentColor, Colors.orange);
      expect(updated.primaryColor, isNull);
    });

    test('copyWith clearPrimary removes primary', () {
      const state = CustomColorsState(
        primaryColor: Colors.red,
        accentColor: Colors.blue,
      );
      final cleared = state.copyWith(clearPrimary: true);
      expect(cleared.primaryColor, isNull);
      expect(cleared.accentColor, Colors.blue);
    });

    test('copyWith clearAccent removes accent', () {
      const state = CustomColorsState(
        primaryColor: Colors.red,
        accentColor: Colors.blue,
      );
      final cleared = state.copyWith(clearAccent: true);
      expect(cleared.primaryColor, Colors.red);
      expect(cleared.accentColor, isNull);
    });
  });

  group('CustomColors (Notifier)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default state has no overrides', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(customColorsProvider);
      await _flushLoad();
      final state = container.read(customColorsProvider);
      expect(state.hasOverrides, isFalse);
    });

    test('loads persisted colors from SharedPreferences', () async {
      const primary = Color(0xFFFF0000);
      const accent = Color(0xFF0000FF);
      SharedPreferences.setMockInitialValues({
        kCustomPrimaryColorKey: primary.toARGB32(),
        kCustomAccentColorKey: accent.toARGB32(),
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(customColorsProvider);
      await _flushLoad();

      final state = container.read(customColorsProvider);
      expect(state.primaryColor, primary);
      expect(state.accentColor, accent);
      expect(state.hasOverrides, isTrue);
    });

    test('setPrimaryColor updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(customColorsProvider);
      await _flushLoad();

      const testColor = Color(0xFFAB1234);
      await container
          .read(customColorsProvider.notifier)
          .setPrimaryColor(testColor);

      expect(container.read(customColorsProvider).primaryColor, testColor);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(kCustomPrimaryColorKey), testColor.toARGB32());
    });

    test('setAccentColor updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(customColorsProvider);
      await _flushLoad();

      const testColor = Color(0xFF5566AA);
      await container
          .read(customColorsProvider.notifier)
          .setAccentColor(testColor);

      expect(container.read(customColorsProvider).accentColor, testColor);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(kCustomAccentColorKey), testColor.toARGB32());
    });

    test('resetColors clears state and removes persisted keys', () async {
      SharedPreferences.setMockInitialValues({
        kCustomPrimaryColorKey: const Color(0xFFFF0000).toARGB32(),
        kCustomAccentColorKey: const Color(0xFF0000FF).toARGB32(),
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(customColorsProvider);
      await _flushLoad();

      expect(container.read(customColorsProvider).hasOverrides, isTrue);

      await container.read(customColorsProvider.notifier).resetColors();

      final state = container.read(customColorsProvider);
      expect(state.primaryColor, isNull);
      expect(state.accentColor, isNull);
      expect(state.hasOverrides, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(kCustomPrimaryColorKey), isNull);
      expect(prefs.getInt(kCustomAccentColorKey), isNull);
    });

    test('persistence keys are the expected strings', () {
      expect(kCustomPrimaryColorKey, 'theme.primary_color');
      expect(kCustomAccentColorKey, 'theme.accent_color');
    });
  });
}
