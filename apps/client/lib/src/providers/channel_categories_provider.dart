/// Collapsed-category state for the Slack/Discord-style channel column.
///
/// Backed by SharedPreferences so the column remembers which category
/// the user collapsed across app launches. Keys are stable strings
/// (`text`, `voice`) rather than the display label so localized
/// renames don't reset the preference.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'channel_categories_provider.g.dart';

const String _kCollapsedKey = 'channel_column_collapsed_categories';

@Riverpod(keepAlive: true)
class ChannelCategoryCollapsed extends _$ChannelCategoryCollapsed {
  @override
  Set<String> build() {
    _load();
    return const <String>{};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kCollapsedKey);
    if (raw == null) return;
    state = raw.toSet();
  }

  Future<void> toggle(String key) async {
    final next = Set<String>.from(state);
    if (!next.add(key)) next.remove(key);
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kCollapsedKey, next.toList());
  }

  bool isCollapsed(String key) => state.contains(key);
}
