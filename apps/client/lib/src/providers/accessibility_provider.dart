import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class AccessibilityNotifier extends StateNotifier<AccessibilityState> {
  AccessibilityNotifier() : super(const AccessibilityState()) {
    _load();
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

final accessibilityProvider =
    StateNotifierProvider<AccessibilityNotifier, AccessibilityState>((ref) {
      return AccessibilityNotifier();
    });
