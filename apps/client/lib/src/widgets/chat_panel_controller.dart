import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ScrollController;

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/chat_provider.dart';

/// Non-rendering state controller for [ChatPanel].
///
/// Owns scroll, pagination, unread-boundary, and floating-date state so the
/// widget's `State` can focus on the build tree. Receives data via method
/// args; it never holds a `WidgetRef` or calls `ref.watch/read/select`.
///
/// Slice 1 (#512): pure helpers only — `isNearBottom`,
/// `filterChannelAndDeleted`, `resolveMessages`. Subsequent slices move
/// scroll, pagination, and unread-boundary state.
class ChatPanelController extends ChangeNotifier {
  ScrollController? _scrollController;

  /// Persistent blocklist of message IDs deleted via "delete for me".
  /// Owned by the widget for now; passed in via [resolveMessages] /
  /// [filterChannelAndDeleted]. Will move into the controller in a later
  /// slice once the SharedPreferences load path migrates.
  Set<String> deletedForMeIds = const {};

  /// Wire in the [ScrollController] managed by the widget's `State`. The
  /// widget keeps ownership (creates + disposes); the controller only reads
  /// from it. Called once from `initState`.
  void attachScrollController(ScrollController controller) {
    _scrollController = controller;
  }

  /// Returns true when the user is within 150px of the bottom of the list.
  /// Defaults to true when the controller has no clients yet so the initial
  /// auto-scroll path runs as if we're already pinned to the bottom.
  bool isNearBottom() {
    final c = _scrollController;
    if (c == null || !c.hasClients) return true;
    final pos = c.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  /// Resolve messages for the current conversation and channel.
  /// Filters out messages the user has deleted locally ("delete for me").
  List<ChatMessage> resolveMessages(
    Conversation conv,
    ChatState chatState,
    String? selectedChannelId,
    bool includeUnchanneled,
  ) {
    final List<ChatMessage> raw;
    if (conv.isGroup) {
      raw = chatState.messagesForConversationChannel(
        conv.id,
        channelId: selectedChannelId,
        includeUnchanneled: includeUnchanneled,
      );
    } else {
      raw = chatState.messagesForConversation(conv.id);
    }
    if (deletedForMeIds.isEmpty) return raw;
    return raw.where((m) => !deletedForMeIds.contains(m.id)).toList();
  }

  /// Apply channel + delete-for-me filters to a pre-fetched message list.
  /// Used by the build path so a `.select` on the per-conversation list ref
  /// keeps unrelated conversations from rebuilding.
  List<ChatMessage> filterChannelAndDeleted(
    Conversation conv,
    List<ChatMessage> raw,
    String? selectedChannelId,
    bool includeUnchanneled,
  ) {
    Iterable<ChatMessage> filtered = raw;
    if (conv.isGroup &&
        selectedChannelId != null &&
        selectedChannelId.isNotEmpty) {
      filtered = filtered.where((m) {
        if (m.isSystemEvent) return true;
        if (m.channelId == selectedChannelId) return true;
        return includeUnchanneled &&
            (m.channelId == null || m.channelId!.isEmpty);
      });
    }
    if (deletedForMeIds.isNotEmpty) {
      filtered = filtered.where((m) => !deletedForMeIds.contains(m.id));
    }
    return identical(filtered, raw) ? raw : filtered.toList();
  }
}
