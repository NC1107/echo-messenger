import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show Curves, ScrollController, WidgetsBinding;

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/chat_provider.dart';

/// Non-rendering state controller for [ChatPanel].
///
/// Owns scroll, pagination, unread-boundary, and floating-date state so the
/// widget's `State` can focus on the build tree. Receives data via method
/// args; it never holds a `WidgetRef` or calls `ref.watch/read/select`.
class ChatPanelController extends ChangeNotifier {
  ScrollController? _scrollController;

  /// Persistent blocklist of message IDs deleted via "delete for me".
  /// Populated from [DeletedForMeStorage.ids] in initState and refreshed
  /// after async load completes.
  Set<String> deletedForMeIds = const {};

  // Per-(conversationId, channelId) dedupe keys for history / channel-list
  // loads and the `ref.listen<ChatState>` autoscroll wiring.
  String? selectedTextChannelId;
  String? loadedHistoryKey;
  String? loadedChannelsConversationId;
  String? autoScrollConversationKey;

  // Per-channel scroll cache keyed `${convId}:${channelId ?? ""}`; capped (oldest evicts first).
  static const int kMaxScrollPositions = 50;
  final Map<String, double> scrollPositions = {};

  // Last-viewed channel per conv — restores channel BEFORE scrollPositions lookup so its "convId:channelId" key hits.
  final Map<String, String?> lastChannelByConversation = {};

  void evictScrollPositions() {
    while (scrollPositions.length > kMaxScrollPositions) {
      scrollPositions.remove(scrollPositions.keys.first);
    }
  }

  String cacheKeyFor(String conversationId) =>
      '$conversationId:${selectedTextChannelId ?? ""}';

  // Unread boundary captured once per channel session; set null to re-arm on conv/channel switch.
  String? unreadBoundaryMessageId;
  int unreadBoundaryCount = 0;

  bool hasNewMessagesBelow = false;
  int newMessagesBelowCount = 0;

  // Floating date pill state. Timer cancelled on conversation switch + dispose.
  String? floatingDate;
  bool floatingDateVisible = false;
  Timer? floatingDateTimer;

  // Snapshotted pre-keyboard-resize because isNearBottom() reads a shifted maxScrollExtent after resize.
  bool wasNearBottom = true;
  double lastKeyboardInset = 0;

  @override
  void dispose() {
    floatingDateTimer?.cancel();
    super.dispose();
  }

  /// Wire in the [ScrollController] managed by the widget's `State`. The
  /// widget keeps ownership (creates + disposes); the controller only reads
  /// from it. Called once from `initState`.
  void attachScrollController(ScrollController controller) {
    _scrollController = controller;
  }

  /// Returns true when the user is within ~3 messages of the bottom of the
  /// list. Defaults to true when the controller has no clients yet so the
  /// initial auto-scroll path runs as if we're already pinned to the bottom.
  ///
  /// The 300px window was chosen so that being two-or-three messages
  /// scrolled up (a normal reading position) still counts as "at the
  /// bottom" — otherwise new messages stay hidden and the user has to
  /// notice the corner pill to see them (#prod-2026-05-21).
  bool isNearBottom() {
    final c = _scrollController;
    if (c == null || !c.hasClients) return true;
    final pos = c.position;
    return pos.maxScrollExtent - pos.pixels < 300;
  }

  /// Pick the oldest non-system message as the pagination cursor.
  ///
  /// System events (`member_joined`, `voice_session_started`, ...) live at
  /// the conversation root with `channelId == null` and surface in every
  /// channel view, but their timestamps predate the actual channel messages
  /// — they're created when the group is born. If we use them as the
  /// pagination cursor, the server's `?channel_id=X&before=<system_ts>`
  /// query (correctly) returns zero rows, `hasMore` flips to false, and
  /// the message list dead-locks at the first page (#prod-2026-05-08).
  /// Falls back to the first message when none is non-system.
  ChatMessage paginationCursor(List<ChatMessage> messages) {
    return messages.firstWhere(
      (m) => !m.isSystemEvent,
      orElse: () => messages.first,
    );
  }

  /// Re-jump to the cached offset across a few frames so we don't land at the
  /// bottom of an empty list while message history is still loading async (#563).
  /// Stops retrying once `maxScrollExtent >= cached`, or after [retries] frames.
  void restoreCachedOffsetWithRetry(double cached, {int retries = 3}) {
    final c = _scrollController;
    if (c == null || !c.hasClients) return;
    final max = c.position.maxScrollExtent;
    c.jumpTo(cached.clamp(0, max));
    if (max < cached && retries > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        restoreCachedOffsetWithRetry(cached, retries: retries - 1);
      });
    }
  }

  void cacheCurrentOffset(String conversationId) {
    final c = _scrollController;
    if (c == null || !c.hasClients) return;
    scrollPositions[cacheKeyFor(conversationId)] = c.offset;
    evictScrollPositions();
  }

  void clearCachedOffset(String conversationId) {
    scrollPositions.remove(cacheKeyFor(conversationId));
  }

  /// Animate (or jump) to `maxScrollExtent` and retry-settle so newly resolved
  /// content (e.g. an image finishing decode) doesn't leave the user a few
  /// pixels short of the bottom.
  void scrollToBottom({
    required String? conversationId,
    bool animated = true,
    int settleRetries = 3,
    VoidCallback? onSettleComplete,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _scrollController;
      if (c == null || !c.hasClients) return;

      final target = c.position.maxScrollExtent;
      if ((target - c.position.pixels).abs() < 1) return;

      final settle = _SettleParams(
        conversationId: conversationId,
        settleRetries: settleRetries,
        onSettleComplete: onSettleComplete,
      );

      if (animated) {
        c
            .animateTo(
              target,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            )
            .whenComplete(() => _settleToBottom(settle));
      } else {
        c.jumpTo(target);
        _settleToBottom(settle);
      }

      // Update the scroll cache. Key includes channel ID so switching text
      // channels within a group preserves separate scroll positions.
      _cacheBottomOffset(conversationId, target);
      onSettleComplete?.call();
    });
  }

  /// One settle pass: waits for layout to stabilise, nudges the scroll
  /// position if the list grew, then recurses via [scrollToBottom].
  Future<void> _settleToBottom(_SettleParams p) async {
    if (p.settleRetries <= 0) return;
    final c = _scrollController;
    if (c == null || !c.hasClients) return;

    // Wait for layout to settle so maxScrollExtent includes new content.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final cc = _scrollController;
    if (cc == null || !cc.hasClients) return;

    final newTarget = cc.position.maxScrollExtent;
    if ((newTarget - cc.position.pixels).abs() > 1) {
      cc.jumpTo(newTarget);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    scrollToBottom(
      conversationId: p.conversationId,
      animated: false,
      settleRetries: p.settleRetries - 1,
      onSettleComplete: p.onSettleComplete,
    );
  }

  void _cacheBottomOffset(String? conversationId, double target) {
    if (conversationId == null) return;
    scrollPositions[cacheKeyFor(conversationId)] = target;
    evictScrollPositions();
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
  /// keeps unrelated conversations from rebuilding (PR #838 perf).
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

/// Parameter bundle passed to [ChatPanelController._settleToBottom] so the
/// private helper does not need a closure over the outer scope.
class _SettleParams {
  const _SettleParams({
    required this.conversationId,
    required this.settleRetries,
    required this.onSettleComplete,
  });

  final String? conversationId;
  final int settleRetries;
  final VoidCallback? onSettleComplete;
}
