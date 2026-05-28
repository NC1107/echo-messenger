/// UI style preset — tracks which chat-app the user is used to so Echo
/// can surface the closest default layout. The visual rendering differences
/// are wired in a follow-up; this PR adds the seam and persistence layer.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'ui_style_provider.g.dart';

/// Which chat-app layout style the user prefers.
///
/// - [discord] — avatar + name on the first message of a sender group;
///   subsequent consecutive messages are indented without repeating the name.
///   This is closest to Echo's current default rendering.
/// - [slack] — avatar + name on every message group, denser feed.
/// - [imessage] — clean bubbles, no sender avatars on consecutive messages,
///   timestamps grouped.
enum UiStyle { discord, slack, imessage }

const _kUiStyleKey = 'ui_style_v1';

@Riverpod(keepAlive: true)
class UiStyleNotifier extends _$UiStyleNotifier {
  @override
  UiStyle build() {
    _load();
    // Discord is the default — closest to today's rendering.
    return UiStyle.discord;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUiStyleKey);
    state = _parse(raw);
  }

  static UiStyle _parse(String? raw) => switch (raw) {
    'slack' => UiStyle.slack,
    'imessage' => UiStyle.imessage,
    _ => UiStyle.discord,
  };

  Future<void> setStyle(UiStyle style) async {
    state = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUiStyleKey, style.name);
  }
}

/// Convenience alias matching the naming pattern in [theme_provider.dart].
final uiStyleProvider = uiStyleNotifierProvider;
