import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'theme_provider.g.dart';

// ---------------------------------------------------------------------------
// Custom color override persistence keys (issue #613)
// ---------------------------------------------------------------------------
const kCustomPrimaryColorKey = 'theme.primary_color';
const kCustomAccentColorKey = 'theme.accent_color';

enum AppThemeSelection {
  system,
  indigo,
  paper,
  graphite,
  ember,
  sakura,
  highContrast,
}

const _kThemeKey = 'echo_theme_mode';
const _kMessageLayoutKey = 'echo_message_layout';
const _kUiDensityKey = 'echo_ui_density';

/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// Class is named `AppTheme` (not `Theme`) to avoid colliding with Flutter's
/// `Theme` widget in importing files; `themeProvider` is preserved via an
/// alias below so call sites are unchanged.
@Riverpod(keepAlive: true)
class AppTheme extends _$AppTheme {
  @override
  AppThemeSelection build() {
    _load();
    return AppThemeSelection.indigo;
  }

  /// Legacy-string migration table. The 9 -> 6 palette reduction renamed
  /// `dark` -> `indigo`, `light` -> `paper`, collapsed `highContrast{Dark,Light}`
  /// into a single `highContrast`, and removed `neon` / `aurora`. Any value
  /// not in [AppThemeSelection.values] by name is migrated silently here.
  static AppThemeSelection _migrateLegacy(String? value) => switch (value) {
    'paper' => AppThemeSelection.paper,
    'indigo' => AppThemeSelection.indigo,
    'system' => AppThemeSelection.system,
    'graphite' => AppThemeSelection.graphite,
    'ember' => AppThemeSelection.ember,
    'sakura' => AppThemeSelection.sakura,
    'highContrast' => AppThemeSelection.highContrast,
    // Legacy renames + cuts (silent migration).
    'dark' => AppThemeSelection.indigo,
    'light' => AppThemeSelection.paper,
    'aurora' => AppThemeSelection.indigo,
    'neon' => AppThemeSelection.highContrast,
    'highContrastDark' => AppThemeSelection.highContrast,
    'highContrastLight' => AppThemeSelection.paper,
    // Unknown / null -> default.
    _ => AppThemeSelection.indigo,
  };

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_kThemeKey);
    final migrated = _migrateLegacy(value);
    state = migrated;
    // One-shot write-back: if the persisted string isn't already the new
    // canonical name, normalise it so subsequent loads skip the migration
    // path and a manual prefs-file inspection shows the new value.
    if (value != migrated.name) {
      await prefs.setString(_kThemeKey, migrated.name);
    }
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
      ThemeMode.dark => AppThemeSelection.indigo,
      ThemeMode.light => AppThemeSelection.paper,
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
final uiDensityProvider = uIDensityNotifierProvider;

// ---------------------------------------------------------------------------
// UI density: cozy (spacious) / normal / compact (Discord-style).
//
// Independent of [MessageLayout] (which controls bubble style). Phase 2 of
// docs/ux-roadmap.md.
// ---------------------------------------------------------------------------

enum UIDensity { cozy, normal, compact }

@Riverpod(keepAlive: true)
class UIDensityNotifier extends _$UIDensityNotifier {
  @override
  UIDensity build() {
    _load();
    // Today's effective default is compact: MessageLayoutNotifier defaults
    // to MessageLayout.compact, which currently shrinks the sidebar.  Match
    // that here so brand-new users (no prefs at all) see no behavior change.
    return UIDensity.compact;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUiDensityKey);
    if (raw == null) {
      // First read after upgrade.  If the user explicitly chose a
      // non-compact MessageLayout (bubbles or plain), their sidebar
      // was rendering at the spacious 68px height — preserve that by
      // setting density to normal.  Otherwise keep the build() default
      // (compact), matching today's behavior.
      final legacy = prefs.getString(_kMessageLayoutKey);
      if (legacy != null && legacy != 'compact') {
        state = UIDensity.normal;
      }
      return;
    }
    state = switch (raw) {
      'cozy' => UIDensity.cozy,
      'compact' => UIDensity.compact,
      _ => UIDensity.normal,
    };
  }

  Future<void> setDensity(UIDensity density) async {
    state = density;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUiDensityKey, density.name);
  }
}

// ---------------------------------------------------------------------------
// Custom color overrides: user-selectable primary and accent (issue #613)
// ---------------------------------------------------------------------------

/// Immutable state for user-chosen color overrides.
/// Null fields mean "use the current theme's default".
@immutable
class CustomColorsState {
  final Color? primaryColor;
  final Color? accentColor;

  const CustomColorsState({this.primaryColor, this.accentColor});

  bool get hasOverrides => primaryColor != null || accentColor != null;

  CustomColorsState copyWith({
    Color? primaryColor,
    Color? accentColor,
    bool clearPrimary = false,
    bool clearAccent = false,
  }) {
    return CustomColorsState(
      primaryColor: clearPrimary ? null : primaryColor ?? this.primaryColor,
      accentColor: clearAccent ? null : accentColor ?? this.accentColor,
    );
  }
}

@Riverpod(keepAlive: true)
class CustomColors extends _$CustomColors {
  @override
  CustomColorsState build() {
    _load();
    return const CustomColorsState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final primaryVal = prefs.getInt(kCustomPrimaryColorKey);
    final accentVal = prefs.getInt(kCustomAccentColorKey);
    state = CustomColorsState(
      primaryColor: primaryVal != null ? Color(primaryVal) : null,
      accentColor: accentVal != null ? Color(accentVal) : null,
    );
  }

  Future<void> setPrimaryColor(Color color) async {
    state = state.copyWith(primaryColor: color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kCustomPrimaryColorKey, color.toARGB32());
  }

  Future<void> setAccentColor(Color color) async {
    state = state.copyWith(accentColor: color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kCustomAccentColorKey, color.toARGB32());
  }

  Future<void> resetColors() async {
    state = const CustomColorsState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kCustomPrimaryColorKey);
    await prefs.remove(kCustomAccentColorKey);
  }
}
