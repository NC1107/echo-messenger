import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/theme_provider.dart';

/// Pump enough microtasks for the build()-fired _load() to settle.
Future<void> _flushLoad() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  group('AppTheme (Notifier)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default theme is dark', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeProvider);
      await _flushLoad();
      expect(container.read(appThemeProvider), AppThemeSelection.dark);
    });

    test('loads persisted theme from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({'echo_theme_mode': 'light'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeProvider);
      await _flushLoad();
      expect(container.read(appThemeProvider), AppThemeSelection.light);
    });

    test('loads all theme variants', () async {
      for (final entry in {
        'system': AppThemeSelection.system,
        'dark': AppThemeSelection.dark,
        'light': AppThemeSelection.light,
        'graphite': AppThemeSelection.graphite,
        'ember': AppThemeSelection.ember,
        'neon': AppThemeSelection.neon,
        'sakura': AppThemeSelection.sakura,
        'aurora': AppThemeSelection.aurora,
      }.entries) {
        SharedPreferences.setMockInitialValues({'echo_theme_mode': entry.key});
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(appThemeProvider);
        await _flushLoad();
        expect(
          container.read(appThemeProvider),
          entry.value,
          reason: '${entry.key} should map to ${entry.value}',
        );
      }
    });

    test('unknown theme value falls back to dark', () async {
      SharedPreferences.setMockInitialValues({'echo_theme_mode': 'unknown'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeProvider);
      await _flushLoad();
      expect(container.read(appThemeProvider), AppThemeSelection.dark);
    });

    test('setTheme updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeProvider);
      await _flushLoad();

      await container
          .read(appThemeProvider.notifier)
          .setTheme(AppThemeSelection.ember);
      expect(container.read(appThemeProvider), AppThemeSelection.ember);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_theme_mode'), 'ember');
    });

    test('setThemeMode maps ThemeMode to AppThemeSelection', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeProvider);
      await _flushLoad();

      final notifier = container.read(appThemeProvider.notifier);
      await notifier.setThemeMode(ThemeMode.light);
      expect(container.read(appThemeProvider), AppThemeSelection.light);

      await notifier.setThemeMode(ThemeMode.dark);
      expect(container.read(appThemeProvider), AppThemeSelection.dark);

      await notifier.setThemeMode(ThemeMode.system);
      expect(container.read(appThemeProvider), AppThemeSelection.system);
    });

    test('legacy themeProvider alias points at the same provider', () {
      // The historical symbol is kept for back-compat; assert it resolves to
      // the same generated provider so call sites can be migrated lazily.
      expect(themeProvider, same(appThemeProvider));
    });
  });

  group('MessageLayoutNotifier (Notifier)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default layout is compact (Discord-style)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(messageLayoutNotifierProvider);
      await _flushLoad();
      expect(
        container.read(messageLayoutNotifierProvider),
        MessageLayout.compact,
      );
    });

    test('loads persisted bubbles layout', () async {
      SharedPreferences.setMockInitialValues({
        'echo_message_layout': 'bubbles',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(messageLayoutNotifierProvider);
      await _flushLoad();
      expect(
        container.read(messageLayoutNotifierProvider),
        MessageLayout.bubbles,
      );
    });

    test('unknown layout value falls back to compact default', () async {
      SharedPreferences.setMockInitialValues({
        'echo_message_layout': 'unknown',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(messageLayoutNotifierProvider);
      await _flushLoad();
      expect(
        container.read(messageLayoutNotifierProvider),
        MessageLayout.compact,
      );
    });

    test('setLayout updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(messageLayoutNotifierProvider);
      await _flushLoad();

      await container
          .read(messageLayoutNotifierProvider.notifier)
          .setLayout(MessageLayout.bubbles);
      expect(
        container.read(messageLayoutNotifierProvider),
        MessageLayout.bubbles,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_message_layout'), 'bubbles');
    });
  });
}
