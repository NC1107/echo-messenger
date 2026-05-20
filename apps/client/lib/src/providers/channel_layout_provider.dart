/// Channel-layout preference (Bar vs Column).
///
/// Echo's default channel surface is a top-of-chat chip row ("Bar" mode).
/// Slack/Discord users tend to prefer a vertical column listing channels
/// down the left edge with categories and voice members nested under
/// each voice channel. The two are visually distinct enough that the
/// app exposes a per-user toggle rather than forcing one style.
///
/// Today this provider drives the new `ChannelColumn` widget visibility
/// in `home_screen.dart`. On narrow viewports the layout is forced back
/// to bar regardless of the saved preference (column doesn't fit in a
/// 390px phone).
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'channel_layout_provider.g.dart';

enum ChannelLayout { bar, column }

@immutable
class ChannelLayoutState {
  final ChannelLayout layout;
  const ChannelLayoutState(this.layout);
}

const String _kChannelLayoutKey = 'channel_layout';

@Riverpod(keepAlive: true)
class ChannelLayoutNotifier extends _$ChannelLayoutNotifier {
  @override
  ChannelLayout build() {
    _load();
    // Default to the existing top-bar style so the preference is
    // additive — current users see no change until they opt in.
    return ChannelLayout.bar;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kChannelLayoutKey);
    if (raw == null) return;
    state = switch (raw) {
      'column' => ChannelLayout.column,
      _ => ChannelLayout.bar,
    };
  }

  Future<void> setLayout(ChannelLayout layout) async {
    if (state == layout) return;
    state = layout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kChannelLayoutKey, layout.name);
  }
}

/// Short alias matching the project's existing provider conventions.
final channelLayoutProvider = channelLayoutNotifierProvider;
