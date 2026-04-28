import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/settings/appearance_section.dart' show kGifAutoplayKey;

/// Combined GIF playback gate: animated GIFs only animate when the user has
/// the autoplay preference on AND the window/app is currently focused. The
/// provider exposes a single [isAnimating] boolean derived from those two
/// inputs so render sites stay simple.
class GifPlaybackState {
  final bool autoplayEnabled;
  final bool appFocused;

  const GifPlaybackState({
    required this.autoplayEnabled,
    required this.appFocused,
  });

  bool get isAnimating => autoplayEnabled && appFocused;

  GifPlaybackState copyWith({bool? autoplayEnabled, bool? appFocused}) {
    return GifPlaybackState(
      autoplayEnabled: autoplayEnabled ?? this.autoplayEnabled,
      appFocused: appFocused ?? this.appFocused,
    );
  }
}

class GifPlaybackNotifier extends StateNotifier<GifPlaybackState>
    with WidgetsBindingObserver {
  GifPlaybackNotifier()
    : super(const GifPlaybackState(autoplayEnabled: true, appFocused: true)) {
    WidgetsBinding.instance.addObserver(this);
    _loadPref();
  }

  Future<void> _loadPref() async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(
      autoplayEnabled: prefs.getBool(kGifAutoplayKey) ?? true,
    );
  }

  /// Persist + apply a new autoplay preference. Called by the Appearance
  /// section toggle so the runtime gate updates without an app restart.
  Future<void> setAutoplay(bool value) async {
    state = state.copyWith(autoplayEnabled: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kGifAutoplayKey, value);
  }

  @override
  // ignore: avoid_renaming_method_parameters
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final focused = lifecycle == AppLifecycleState.resumed;
    state = state.copyWith(appFocused: focused);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final gifPlaybackProvider =
    StateNotifierProvider<GifPlaybackNotifier, GifPlaybackState>(
      (ref) => GifPlaybackNotifier(),
    );
