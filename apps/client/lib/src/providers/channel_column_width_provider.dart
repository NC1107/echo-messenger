/// Persisted width of the Slack/Discord-style channel column.
///
/// The column lives between the conversation sidebar and the chat
/// panel on viewports >= 900 px (`useColumn` in chat_panel_body.dart).
/// Users can drag its right edge to resize it; the chosen width is
/// stored in SharedPreferences so each launch restores the same
/// layout.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'channel_column_width_provider.g.dart';

const String _kColumnWidthKey = 'channel_column_width';

/// Default column width — matches the Slack / Discord visual baseline
/// and fits comfortably on a 1280-wide desktop window alongside the
/// conversation sidebar, chat panel and members panel.
const double channelColumnDefaultWidth = 260;
const double channelColumnMinWidth = 180;
const double channelColumnMaxWidth = 420;

@Riverpod(keepAlive: true)
class ChannelColumnWidth extends _$ChannelColumnWidth {
  @override
  double build() {
    _load();
    return channelColumnDefaultWidth;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getDouble(_kColumnWidthKey);
    if (raw == null) return;
    state = raw.clamp(channelColumnMinWidth, channelColumnMaxWidth);
  }

  Future<void> setWidth(double width) async {
    final clamped = width.clamp(channelColumnMinWidth, channelColumnMaxWidth);
    if (clamped == state) return;
    state = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kColumnWidthKey, clamped);
  }
}
