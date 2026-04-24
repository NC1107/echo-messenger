import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/theme_provider.dart';

void main() {
  group('ThemeNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default theme is dark', () async {
      final notifier = ThemeNotifier();
      // Allow async _load to run.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state, AppThemeSelection.dark);
      notifier.dispose();
    });

    test('loads persisted theme from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({'echo_theme_mode': 'light'});
      final notifier = ThemeNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state, AppThemeSelection.light);
      notifier.dispose();
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
        final notifier = ThemeNotifier();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          notifier.state,
          entry.value,
          reason: '${entry.key} should map to ${entry.value}',
        );
        notifier.dispose();
      }
    });

    test('unknown theme value falls back to dark', () async {
      SharedPreferences.setMockInitialValues({'echo_theme_mode': 'unknown'});
      final notifier = ThemeNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state, AppThemeSelection.dark);
      notifier.dispose();
    });

    test('setTheme updates state and persists', () async {
      final notifier = ThemeNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setTheme(AppThemeSelection.ember);
      expect(notifier.state, AppThemeSelection.ember);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_theme_mode'), 'ember');
      notifier.dispose();
    });

    test('setThemeMode maps ThemeMode to AppThemeSelection', () async {
      final notifier = ThemeNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setThemeMode(ThemeMode.light);
      expect(notifier.state, AppThemeSelection.light);

      await notifier.setThemeMode(ThemeMode.dark);
      expect(notifier.state, AppThemeSelection.dark);

      await notifier.setThemeMode(ThemeMode.system);
      expect(notifier.state, AppThemeSelection.system);
      notifier.dispose();
    });
  });

  group('MessageLayoutNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default layout is compact (Discord-style)', () async {
      final notifier = MessageLayoutNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state, MessageLayout.compact);
      notifier.dispose();
    });

    test('loads persisted bubbles layout', () async {
      SharedPreferences.setMockInitialValues({
        'echo_message_layout': 'bubbles',
      });
      final notifier = MessageLayoutNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state, MessageLayout.bubbles);
      notifier.dispose();
    });

    test('unknown layout value falls back to compact default', () async {
      SharedPreferences.setMockInitialValues({
        'echo_message_layout': 'unknown',
      });
      final notifier = MessageLayoutNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state, MessageLayout.compact);
      notifier.dispose();
    });

    test('setLayout updates state and persists', () async {
      final notifier = MessageLayoutNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setLayout(MessageLayout.bubbles);
      expect(notifier.state, MessageLayout.bubbles);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('echo_message_layout'), 'bubbles');
      notifier.dispose();
    });
  });
}
