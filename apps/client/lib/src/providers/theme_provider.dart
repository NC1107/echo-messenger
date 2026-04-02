import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeSelection { system, dark, light, graphite }

class ThemeNotifier extends StateNotifier<AppThemeSelection> {
  static const _key = 'echo_theme_mode';

  ThemeNotifier() : super(AppThemeSelection.dark) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    state = switch (value) {
      'light' => AppThemeSelection.light,
      'dark' => AppThemeSelection.dark,
      'system' => AppThemeSelection.system,
      'graphite' => AppThemeSelection.graphite,
      _ => AppThemeSelection.dark,
    };
  }

  Future<void> setTheme(AppThemeSelection selection) async {
    state = selection;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, selection.name);
  }

  // Keep this for existing callers that still use ThemeMode.
  Future<void> setThemeMode(ThemeMode mode) async {
    final selection = switch (mode) {
      ThemeMode.system => AppThemeSelection.system,
      ThemeMode.dark => AppThemeSelection.dark,
      ThemeMode.light => AppThemeSelection.light,
    };
    await setTheme(selection);
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, AppThemeSelection>((ref) {
  return ThemeNotifier();
});
