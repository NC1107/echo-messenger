import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversations_provider.dart';
import '../../utils/semantics_preview.dart';
import '../chat_panel_controller.dart';
import 'message_actions.dart' show fullMonthName;

/// Find the topmost rendered message by querying RenderBox positions.
String? _findTopmostMessageId(Map<String, GlobalKey> messageKeys) {
  String? topmostId;
  double closestY = double.infinity;
  for (final entry in messageKeys.entries) {
    final ctx = entry.value.currentContext;
    if (ctx == null) continue;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) continue;
    final y = box.localToGlobal(Offset.zero).dy;
    if (y < closestY) {
      closestY = y;
      topmostId = entry.key;
    }
  }
  return topmostId;
}

/// Format a date as "Today", "Yesterday", or "Month Day, Year".
String _formatDateLabel(DateTime dt, DateTime now) {
  final yesterday = now.subtract(const Duration(days: 1));
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return 'Today';
  } else if (dt.year == yesterday.year &&
      dt.month == yesterday.month &&
      dt.day == yesterday.day) {
    return 'Yesterday';
  } else {
    return '${fullMonthName(dt.month)} ${dt.day}, ${dt.year}';
  }
}

/// Update the floating date pill so it reflects the date of the topmost
/// rendered message. Cancels and reschedules the 2s fade-out timer.
void updateFloatingDate({
  required WidgetRef ref,
  required Conversation conv,
  required ScrollController scrollController,
  required Map<String, GlobalKey> messageKeys,
  required String? selectedTextChannelId,
  required List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages,
  required ChatPanelController controller,
  required void Function(VoidCallback) setState,
  required bool Function() mounted,
}) {
  if (!scrollController.hasClients) return;

  final chatState = ref.read(chatProvider);
  final selectedChannelId = conv.isGroup ? selectedTextChannelId : null;
  final includeUnchanneled = conv.isGroup && selectedTextChannelId == null;
  final messages = resolveMessages(
    conv,
    chatState,
    selectedChannelId,
    includeUnchanneled,
  );
  if (messages.isEmpty) return;

  final topmostId = _findTopmostMessageId(messageKeys);
  final msgIndex = topmostId == null
      ? 0
      : messages
            .indexWhere((m) => m.id == topmostId)
            .clamp(0, messages.length - 1);

  try {
    final dt = DateTime.parse(messages[msgIndex].timestamp).toLocal();
    final now = DateTime.now();
    final label = _formatDateLabel(dt, now);

    if (label != controller.floatingDate || !controller.floatingDateVisible) {
      setState(() {
        controller.floatingDate = label;
        controller.floatingDateVisible = true;
      });
    }
  } catch (_) {
    return;
  }

  controller.floatingDateTimer?.cancel();
  controller.floatingDateTimer = Timer(const Duration(seconds: 2), () {
    if (mounted()) setState(() => controller.floatingDateVisible = false);
  });
}

/// Compute the unread boundary message ID from the current unread count.
/// Called once when a conversation is first opened or messages finish
/// loading. Invariant #6: single-capture-per-channel-session guard.
void captureUnreadBoundary({
  required WidgetRef ref,
  required Conversation conv,
  required String? selectedTextChannelId,
  required ChatPanelController controller,
  required List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages,
  required void Function(VoidCallback) setState,
}) {
  // Only capture once per conversation open
  if (controller.unreadBoundaryMessageId != null) return;

  final convState = ref.read(conversationsProvider);
  final convData = convState.conversations
      .where((c) => c.id == conv.id)
      .firstOrNull;
  if (convData == null || convData.unreadCount <= 0) return;

  final chatState = ref.read(chatProvider);
  final selectedChannelId = conv.isGroup ? selectedTextChannelId : null;
  final includeUnchanneled = conv.isGroup && selectedTextChannelId == null;
  final messages = resolveMessages(
    conv,
    chatState,
    selectedChannelId,
    includeUnchanneled,
  );
  if (messages.isEmpty) return;

  final boundaryIndex = messages.length - convData.unreadCount;
  if (boundaryIndex > 0 && boundaryIndex < messages.length) {
    setState(() {
      controller.unreadBoundaryMessageId = messages[boundaryIndex].id;
      controller.unreadBoundaryCount = convData.unreadCount;
    });
  }
}

/// Scroll to the unread boundary divider so it appears near the top.
void scrollToUnreadBoundary({
  required ScrollController scrollController,
  required Map<String, GlobalKey> messageKeys,
  required List<ChatMessage> messages,
  required String? unreadBoundaryMessageId,
}) {
  if (unreadBoundaryMessageId == null) return;
  final index = messages.indexWhere((m) => m.id == unreadBoundaryMessageId);
  if (index < 0 || !scrollController.hasClients) return;

  // Use Scrollable.ensureVisible if the key is available for pixel-accurate
  // positioning; fall back to a jump when the item is not yet rendered.
  final key = messageKeys[unreadBoundaryMessageId];
  if (key?.currentContext != null) {
    Scrollable.ensureVisible(
      key!.currentContext!,
      alignment: 0.15,
      duration: Duration.zero,
    );
  } else {
    // Item not rendered yet — scroll by index (approximate).
    final estimatedOffset = (index + 1) * 60.0 - 120.0;
    scrollController.jumpTo(
      estimatedOffset.clamp(0, scrollController.position.maxScrollExtent),
    );
  }
}

/// Off-screen-aware scroll-to-message. Uses `Scrollable.ensureVisible` when
/// the target widget is rendered; falls back to an estimated jump + retry.
void scrollToMessage({
  required String messageId,
  required ScrollController scrollController,
  required Map<String, GlobalKey> messageKeys,
  required List<ChatMessage> messages,
}) {
  final key = messageKeys[messageId];
  if (key?.currentContext != null) {
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.3,
    );
    return;
  }

  // Target message is off-screen (not rendered by ListView.builder).
  // Find its index and estimate scroll position to jump near it.
  if (!scrollController.hasClients) return;
  final index = messages.indexWhere((m) => m.id == messageId);
  if (index < 0) return;

  // +1 accounts for the loading indicator at index 0 in the ListView.
  final estimatedOffset = (index + 1) * 60.0;
  scrollController.animateTo(
    estimatedOffset.clamp(0, scrollController.position.maxScrollExtent),
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOut,
  );

  // After the jump, retry with ensureVisible once the widget is rendered.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final retryKey = messageKeys[messageId];
    if (retryKey?.currentContext != null) {
      Scrollable.ensureVisible(
        retryKey!.currentContext!,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.3,
      );
    }
  });
}

/// Handle unread boundary capture when messages first load.
void _handleInitialMessageLoad(
  int prevCount,
  int nextCount,
  ChatPanelController controller,
  void Function() onCaptureUnreadBoundary,
  void Function() onScrollToUnreadBoundary,
) {
  if (prevCount == 0 &&
      nextCount > 0 &&
      controller.unreadBoundaryMessageId == null) {
    onCaptureUnreadBoundary();
    if (controller.unreadBoundaryMessageId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onScrollToUnreadBoundary();
      });
    }
  }
}

/// Announce new message to assistive tech and manage timer.
void _announceNewMessage(
  ChatMessage newest,
  String? lastAnnouncedId,
  String myUserId,
  Timer? Function() getLiveRegionClearTimer,
  void Function(String?) setLastAnnouncedMessageId,
  void Function(String) setLiveRegionAnnouncement,
  void Function(Timer?) setLiveRegionClearTimer,
  void Function(VoidCallback) setState,
  bool Function() mounted,
) {
  if (newest.id == lastAnnouncedId ||
      newest.fromUserId == myUserId ||
      newest.isSystemEvent) {
    return;
  }
  setLastAnnouncedMessageId(newest.id);
  final preview = previewForSemantics(newest.content);
  setState(() {
    setLiveRegionAnnouncement(
      preview.isEmpty
          ? 'New message from ${newest.fromUsername}'
          : 'New message from ${newest.fromUsername}: $preview',
    );
  });
  getLiveRegionClearTimer()?.cancel();
  setLiveRegionClearTimer(
    Timer(const Duration(seconds: 3), () {
      if (!mounted()) return;
      setState(() => setLiveRegionAnnouncement(''));
    }),
  );
}

/// Handle auto-scroll and new message notification for incoming messages.
void _handleIncomingMessages(
  int prevCount,
  int nextCount,
  ChatState next,
  Conversation conv,
  WidgetRef ref,
  String? Function() getLastAnnouncedMessageId,
  void Function(String?) setLastAnnouncedMessageId,
  void Function(String) setLiveRegionAnnouncement,
  Timer? Function() getLiveRegionClearTimer,
  void Function(Timer?) setLiveRegionClearTimer,
  bool Function() isNearBottom,
  void Function() scrollToBottom,
  ChatPanelController controller,
  void Function(VoidCallback) setState,
  bool Function() mounted,
) {
  final myUserId = ref.read(authProvider.select((s) => s.userId)) ?? '';
  final newest = next.messagesForConversation(conv.id).lastOrNull;
  if (newest != null && prevCount > 0) {
    _announceNewMessage(
      newest,
      getLastAnnouncedMessageId(),
      myUserId,
      getLiveRegionClearTimer,
      setLastAnnouncedMessageId,
      setLiveRegionAnnouncement,
      setLiveRegionClearTimer,
      setState,
      mounted,
    );
  }

  if (isNearBottom()) {
    scrollToBottom();
  } else {
    setState(() {
      controller.hasNewMessagesBelow = true;
      controller.newMessagesBelowCount += nextCount - prevCount;
    });
  }
}

/// Wire up the per-channel-session `ref.listen<ChatState>(chatProvider)`
/// that drives auto-scroll on incoming messages and the assistive-tech
/// live-region announcement (#495).
void setupAutoScroll({
  required WidgetRef ref,
  required Conversation conv,
  required String? selectedChannelId,
  required bool includeUnchanneled,
  required ChatPanelController controller,
  required String? Function() getLastAnnouncedMessageId,
  required void Function(String?) setLastAnnouncedMessageId,
  required void Function(String) setLiveRegionAnnouncement,
  required Timer? Function() getLiveRegionClearTimer,
  required void Function(Timer?) setLiveRegionClearTimer,
  required bool Function() isNearBottom,
  required void Function() scrollToBottom,
  required void Function() onCaptureUnreadBoundary,
  required void Function() onScrollToUnreadBoundary,
  required void Function(VoidCallback) setState,
  required bool Function() mounted,
}) {
  final key = '${conv.id}:${selectedChannelId ?? ""}';
  if (controller.autoScrollConversationKey == key) return;
  controller.autoScrollConversationKey = key;

  ref.listen<ChatState>(chatProvider, (prev, next) {
    int visibleCount(ChatState s) {
      if (!conv.isGroup) return s.messagesForConversation(conv.id).length;
      return s
          .messagesForConversationChannel(
            conv.id,
            channelId: selectedChannelId,
            includeUnchanneled: includeUnchanneled,
          )
          .length;
    }

    final prevCount = prev == null ? 0 : visibleCount(prev);
    final nextCount = visibleCount(next);

    _handleInitialMessageLoad(
      prevCount,
      nextCount,
      controller,
      onCaptureUnreadBoundary,
      onScrollToUnreadBoundary,
    );

    if (nextCount > prevCount) {
      _handleIncomingMessages(
        prevCount,
        nextCount,
        next,
        conv,
        ref,
        getLastAnnouncedMessageId,
        setLastAnnouncedMessageId,
        setLiveRegionAnnouncement,
        getLiveRegionClearTimer,
        setLiveRegionClearTimer,
        isNearBottom,
        scrollToBottom,
        controller,
        setState,
        mounted,
      );
    }
  });
}
