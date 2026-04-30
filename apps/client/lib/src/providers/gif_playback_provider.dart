import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/settings/appearance_section.dart' show kGifAutoplayKey;

part 'gif_playback_provider.g.dart';

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

/// A `WidgetsBindingObserver` lives outside the notifier so we can register
/// it in [GifPlayback.build] and detach via `ref.onDispose`. Riverpod's
/// Notifier lifecycle ties cleanup to the provider being disposed (or
/// invalidated), not to a class instance, so we use a callback observer
/// instead of `class GifPlayback ... with WidgetsBindingObserver` to make
/// the listener removal symmetrical with attachment.
class _GifFocusObserver with WidgetsBindingObserver {
  _GifFocusObserver(this._onFocusChanged);
  final void Function(bool focused) _onFocusChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    _onFocusChanged(lifecycle == AppLifecycleState.resumed);
  }
}

/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// `keepAlive: true` matches the singleton lifetime of the original
/// `StateNotifierProvider`. Lifecycle-observer detach happens through
/// `ref.onDispose` instead of an overridden `dispose()`.
@Riverpod(keepAlive: true)
class GifPlayback extends _$GifPlayback {
  @override
  GifPlaybackState build() {
    final observer = _GifFocusObserver(
      (focused) => state = state.copyWith(appFocused: focused),
    );
    WidgetsBinding.instance.addObserver(observer);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(observer);
    });

    _loadPref();
    return const GifPlaybackState(autoplayEnabled: true, appFocused: true);
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
}
