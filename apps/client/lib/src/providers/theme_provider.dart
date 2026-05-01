import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'theme_provider.g.dart';

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

const _kThemeKey = 'echo_theme_mode';
const _kMessageLayoutKey = 'echo_message_layout';

/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// Class is named `AppTheme` (not `Theme`) to avoid colliding with Flutter's
/// `Theme` widget in importing files; `themeProvider` is preserved via an
/// alias below so call sites are unchanged.
@Riverpod(keepAlive: true)
class AppTheme extends _$AppTheme {
  @override
  AppThemeSelection build() {
    _load();
    return AppThemeSelection.dark;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_kThemeKey);
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
    await prefs.setString(_kThemeKey, selection.name);
  }

  /// Backwards-compat surface for callers that still pass [ThemeMode].
  Future<void> setThemeMode(ThemeMode mode) async {
    final selection = switch (mode) {
      ThemeMode.system => AppThemeSelection.system,
      ThemeMode.dark => AppThemeSelection.dark,
      ThemeMode.light => AppThemeSelection.light,
    };
    await setTheme(selection);
  }
}

// ---------------------------------------------------------------------------
// Message layout: compact (Discord-style, default), bubbles, or plain (Slack)
// ---------------------------------------------------------------------------

enum MessageLayout { bubbles, compact, plain }

@Riverpod(keepAlive: true)
class MessageLayoutNotifier extends _$MessageLayoutNotifier {
  @override
  MessageLayout build() {
    _load();
    return MessageLayout.compact;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_kMessageLayoutKey);
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
    await prefs.setString(_kMessageLayoutKey, layout.name);
  }
}

/// Aliases preserving the legacy provider symbols used by existing call
/// sites and tests. Riverpod codegen derives the provider name from the
/// notifier class name; we keep `class AppTheme` (not `Theme`, which would
/// collide with Flutter's Material `Theme`) and `class MessageLayoutNotifier`
/// (not `MessageLayout`, which is the enum), then re-export the historical
/// short names.
final themeProvider = appThemeProvider;
final messageLayoutProvider = messageLayoutNotifierProvider;
