import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeSelection {
  system,
  dark,
  light,
  graphite,
  ember,
  neon,
  sakura,
  aurora,
}

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
      'ember' => AppThemeSelection.ember,
      'neon' => AppThemeSelection.neon,
      'sakura' => AppThemeSelection.sakura,
      'aurora' => AppThemeSelection.aurora,
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

final themeProvider = StateNotifierProvider<ThemeNotifier, AppThemeSelection>((
  ref,
) {
  return ThemeNotifier();
});

// ---------------------------------------------------------------------------
// Message layout: compact (Discord-style, default), bubbles, or plain (Slack)
// ---------------------------------------------------------------------------

enum MessageLayout { bubbles, compact, plain }

class MessageLayoutNotifier extends StateNotifier<MessageLayout> {
  static const _key = 'echo_message_layout';

  MessageLayoutNotifier() : super(MessageLayout.compact) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    state = switch (value) {
      'bubbles' => MessageLayout.bubbles,
      'compact' => MessageLayout.compact,
      'plain' => MessageLayout.plain,
      _ => MessageLayout.compact,
    };
  }

  Future<void> setLayout(MessageLayout layout) async {
    state = layout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, layout.name);
  }
}

final messageLayoutProvider =
    StateNotifierProvider<MessageLayoutNotifier, MessageLayout>((ref) {
      return MessageLayoutNotifier();
    });
