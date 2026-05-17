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

/// Parameters for updating the floating date pill.
typedef FloatingDateParams = ({
  WidgetRef ref,
  Conversation conv,
  ScrollController scrollController,
  Map<String, GlobalKey> messageKeys,
  String? selectedTextChannelId,
  List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages,
  ChatPanelController controller,
  void Function(VoidCallback) setState,
  bool Function() mounted,
});

/// Parameters for announcing incoming messages to assistive tech.
typedef AnnounceNewMessageParams = ({
  ChatMessage newest,
  String? lastAnnouncedId,
  String myUserId,
  Timer? Function() getLiveRegionClearTimer,
  void Function(String?) setLastAnnouncedMessageId,
  void Function(String) setLiveRegionAnnouncement,
  void Function(Timer?) setLiveRegionClearTimer,
  void Function(VoidCallback) setState,
  bool Function() mounted,
});

/// Parameters for handling incoming message updates.
typedef IncomingMessagesParams = ({
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
});

/// Parameters for setting up auto-scroll functionality.
typedef AutoScrollParams = ({
  WidgetRef ref,
  Conversation conv,
  String? selectedChannelId,
  bool includeUnchanneled,
  ChatPanelController controller,
  String? Function() getLastAnnouncedMessageId,
  void Function(String?) setLastAnnouncedMessageId,
  void Function(String) setLiveRegionAnnouncement,
  Timer? Function() getLiveRegionClearTimer,
  void Function(Timer?) setLiveRegionClearTimer,
  bool Function() isNearBottom,
  void Function() scrollToBottom,
  void Function() onCaptureUnreadBoundary,
  void Function() onScrollToUnreadBoundary,
  void Function(VoidCallback) setState,
  bool Function() mounted,
});

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
void updateFloatingDate(FloatingDateParams params) {
  if (!params.scrollController.hasClients) return;

  final chatState = params.ref.read(chatProvider);
  final selectedChannelId = params.conv.isGroup
      ? params.selectedTextChannelId
      : null;
  final includeUnchanneled =
      params.conv.isGroup && params.selectedTextChannelId == null;
  final messages = params.resolveMessages(
    params.conv,
    chatState,
    selectedChannelId,
    includeUnchanneled,
  );
  if (messages.isEmpty) return;

  final topmostId = _findTopmostMessageId(params.messageKeys);
  final msgIndex = topmostId == null
      ? 0
      : messages
            .indexWhere((m) => m.id == topmostId)
            .clamp(0, messages.length - 1);

  try {
    final dt = DateTime.parse(messages[msgIndex].timestamp).toLocal();
    final now = DateTime.now();
    final label = _formatDateLabel(dt, now);

    if (label != params.controller.floatingDate ||
        !params.controller.floatingDateVisible) {
      params.setState(() {
        params.controller.floatingDate = label;
        params.controller.floatingDateVisible = true;
      });
    }
  } catch (_) {
    return;
  }

  params.controller.floatingDateTimer?.cancel();
  params.controller.floatingDateTimer = Timer(const Duration(seconds: 2), () {
    if (params.mounted()) {
      params.setState(() => params.controller.floatingDateVisible = false);
    }
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
void _announceNewMessage(AnnounceNewMessageParams params) {
  if (params.newest.id == params.lastAnnouncedId ||
      params.newest.fromUserId == params.myUserId ||
      params.newest.isSystemEvent) {
    return;
  }
  params.setLastAnnouncedMessageId(params.newest.id);
  final preview = previewForSemantics(params.newest.content);
  params.setState(() {
    params.setLiveRegionAnnouncement(
      preview.isEmpty
          ? 'New message from ${params.newest.fromUsername}'
          : 'New message from ${params.newest.fromUsername}: $preview',
    );
  });
  params.getLiveRegionClearTimer()?.cancel();
  params.setLiveRegionClearTimer(
    Timer(const Duration(seconds: 3), () {
      if (!params.mounted()) return;
      params.setState(() => params.setLiveRegionAnnouncement(''));
    }),
  );
}

/// Handle auto-scroll and new message notification for incoming messages.
void _handleIncomingMessages(IncomingMessagesParams params) {
  final myUserId = params.ref.read(authProvider.select((s) => s.userId)) ?? '';
  final newest = params.next.messagesForConversation(params.conv.id).lastOrNull;
  if (newest != null && params.prevCount > 0) {
    _announceNewMessage((
      newest: newest,
      lastAnnouncedId: params.getLastAnnouncedMessageId(),
      myUserId: myUserId,
      getLiveRegionClearTimer: params.getLiveRegionClearTimer,
      setLastAnnouncedMessageId: params.setLastAnnouncedMessageId,
      setLiveRegionAnnouncement: params.setLiveRegionAnnouncement,
      setLiveRegionClearTimer: params.setLiveRegionClearTimer,
      setState: params.setState,
      mounted: params.mounted,
    ));
  }

  if (params.isNearBottom()) {
    params.scrollToBottom();
  } else {
    params.setState(() {
      params.controller.hasNewMessagesBelow = true;
      params.controller.newMessagesBelowCount +=
          params.nextCount - params.prevCount;
    });
  }
}

/// Wire up the per-channel-session `ref.listen<ChatState>(chatProvider)`
/// that drives auto-scroll on incoming messages and the assistive-tech
/// live-region announcement (#495).
void setupAutoScroll(AutoScrollParams params) {
  final key = '${params.conv.id}:${params.selectedChannelId ?? ""}';
  if (params.controller.autoScrollConversationKey == key) return;
  params.controller.autoScrollConversationKey = key;

  params.ref.listen<ChatState>(chatProvider, (prev, next) {
    int visibleCount(ChatState s) {
      if (!params.conv.isGroup) {
        return s.messagesForConversation(params.conv.id).length;
      }
      return s
          .messagesForConversationChannel(
            params.conv.id,
            channelId: params.selectedChannelId,
            includeUnchanneled: params.includeUnchanneled,
          )
          .length;
    }

    final prevCount = prev == null ? 0 : visibleCount(prev);
    final nextCount = visibleCount(next);

    _handleInitialMessageLoad(
      prevCount,
      nextCount,
      params.controller,
      params.onCaptureUnreadBoundary,
      params.onScrollToUnreadBoundary,
    );

    if (nextCount > prevCount) {
      _handleIncomingMessages((
        prevCount: prevCount,
        nextCount: nextCount,
        next: next,
        conv: params.conv,
        ref: params.ref,
        getLastAnnouncedMessageId: params.getLastAnnouncedMessageId,
        setLastAnnouncedMessageId: params.setLastAnnouncedMessageId,
        setLiveRegionAnnouncement: params.setLiveRegionAnnouncement,
        getLiveRegionClearTimer: params.getLiveRegionClearTimer,
        setLiveRegionClearTimer: params.setLiveRegionClearTimer,
        isNearBottom: params.isNearBottom,
        scrollToBottom: params.scrollToBottom,
        controller: params.controller,
        setState: params.setState,
        mounted: params.mounted,
      ));
    }
  });
}
