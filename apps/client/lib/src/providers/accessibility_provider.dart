import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'accessibility_provider.g.dart';

const kAccessibilityFontScale = 'accessibility_font_scale';
const kAccessibilityReducedMotion = 'accessibility_reduced_motion';
const kAccessibilityHighContrast = 'accessibility_high_contrast';

class AccessibilityState {
  final double fontScale;
  final bool reducedMotion;
  final bool highContrast;

  const AccessibilityState({
    this.fontScale = 1.0,
    this.reducedMotion = false,
    this.highContrast = false,
  });

  AccessibilityState copyWith({
    double? fontScale,
    bool? reducedMotion,
    bool? highContrast,
  }) {
    return AccessibilityState(
      fontScale: fontScale ?? this.fontScale,
      reducedMotion: reducedMotion ?? this.reducedMotion,
      highContrast: highContrast ?? this.highContrast,
    );
  }
}

/// Migrated from `StateNotifier` to `@riverpod`-annotated `Notifier` (audit
/// 2026-04-30, Riverpod modernization slice). The exported provider symbol
/// `accessibilityProvider` is preserved so the ~12 existing call sites do
/// not change.
///
/// `keepAlive: true` matches the original `StateNotifierProvider` semantics
/// -- the singleton lives for the whole app session so we don't re-run
/// `_load()` (a SharedPreferences read) every time a widget re-watches.
@Riverpod(keepAlive: true)
class Accessibility extends _$Accessibility {
  @override
  AccessibilityState build() {
    // Fire and forget: load persisted prefs and overwrite `state` once
    // the future resolves. Matches the legacy StateNotifier behaviour.
    _load();
    return const AccessibilityState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AccessibilityState(
      fontScale: prefs.getDouble(kAccessibilityFontScale) ?? 1.0,
      reducedMotion: prefs.getBool(kAccessibilityReducedMotion) ?? false,
      highContrast: prefs.getBool(kAccessibilityHighContrast) ?? false,
    );
  }

  Future<void> setFontScale(double value) async {
    state = state.copyWith(fontScale: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kAccessibilityFontScale, value);
  }

  Future<void> setReducedMotion(bool value) async {
    state = state.copyWith(reducedMotion: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAccessibilityReducedMotion, value);
  }

  Future<void> setHighContrast(bool value) async {
    state = state.copyWith(highContrast: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAccessibilityHighContrast, value);
  }
}
