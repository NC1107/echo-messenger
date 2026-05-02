// Message-list rendering extracted from ChatPanel (round 2 refactor).
//
// Pure mechanical extraction: no behavior change. Owns the
// skeleton/empty-state/list-with-scrollbar AnimatedSwitcher and the
// per-row build logic (date dividers, unread divider, grouping windows,
// system timeline rows). The parent ChatPanel still owns the
// ScrollController (which drives the floating-date pill / new-messages
// pill) and passes it down.
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../providers/accessibility_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/echo_theme.dart';
import '../message_item.dart';
import '../skeleton_loader.dart';
import 'date_divider.dart';
import 'empty_message_placeholder.dart';
import 'system_timeline_message.dart';
import 'unread_divider.dart';

/// Message-list section of [ChatPanel]. Renders the skeleton while
/// history is loading, an empty-state placeholder when there are no
/// messages, or the scrollable [ListView.builder] of message rows.
class ChatMessageList extends ConsumerWidget {
  final Conversation conv;
  final List<ChatMessage> messages;
  final ChatState chatState;
  final Map<String, String?> memberAvatars;
  final String myUserId;
  final String serverUrl;
  final String authToken;
  final String? mediaTicket;
  final String? channelId;
  final bool isLoadingHistory;
  final String displayName;

  /// Owned by parent [ChatPanel]; drives the floating-date pill and
  /// new-messages pill from the parent's scroll listener.
  final ScrollController scrollController;

  /// Parent-owned mutable map of message id -> GlobalKey so the parent
  /// can scroll to and highlight specific messages (jump-to-reply,
  /// unread boundary, etc.). Keys are inserted lazily as rows render.
  final Map<String, GlobalKey> messageKeys;

  /// Parent-owned set of message ids saved in this session. Kept here
  /// (rather than reading [SavedMessagesService] directly) so the
  /// parent can drive optimistic updates via setState.
  final Set<String> savedIds;

  final String? highlightedMessageId;
  final String? unreadBoundaryMessageId;
  final int unreadBoundaryCount;

  // --- Callbacks ----------------------------------------------------------

  final void Function(ChatMessage message, Offset globalPosition) onReactionTap;
  final void Function(ChatMessage message, String emoji, bool alreadyReacted)
  onToggleReaction;
  final void Function(ChatMessage message) onMoreReactions;
  final void Function(ChatMessage message) onDeleteFailed;
  final void Function(ChatMessage message) onConfirmDelete;
  final void Function(ChatMessage message) onRetryMessage;
  final void Function(ChatMessage message) onEnterEditMode;
  final void Function(ChatMessage message) onReply;
  final void Function(ChatMessage message) onOpenThread;
  final void Function(ChatMessage message) onPin;
  final void Function(ChatMessage message) onUnpin;
  final void Function(ChatMessage message) onForward;
  final void Function(ChatMessage message) onSaveMessage;
  final void Function(ChatMessage message) onUnsaveMessage;
  final void Function(String replyToId) onJumpToReplyQuote;
  final void Function(String userId) onAvatarTap;

  /// Null on group conversations to disable the verify-identity affordance.
  final void Function(ChatMessage message)? onVerifyIdentity;

  final void Function(String resolvedUrl) onImageTap;

  /// Predicate for whether a given message id is currently saved (used
  /// for both the in-session optimistic [savedIds] and the persistent
  /// [SavedMessagesService] check the parent already does inline).
  final bool Function(String messageId) isMessageSaved;

  /// Tapped from the empty-state placeholder.
  final VoidCallback onSayHi;

  const ChatMessageList({
    super.key,
    required this.conv,
    required this.messages,
    required this.chatState,
    required this.memberAvatars,
    required this.myUserId,
    required this.serverUrl,
    required this.authToken,
    required this.mediaTicket,
    required this.channelId,
    required this.isLoadingHistory,
    required this.displayName,
    required this.scrollController,
    required this.messageKeys,
    required this.savedIds,
    required this.highlightedMessageId,
    required this.unreadBoundaryMessageId,
    required this.unreadBoundaryCount,
    required this.onReactionTap,
    required this.onToggleReaction,
    required this.onMoreReactions,
    required this.onDeleteFailed,
    required this.onConfirmDelete,
    required this.onRetryMessage,
    required this.onEnterEditMode,
    required this.onReply,
    required this.onOpenThread,
    required this.onPin,
    required this.onUnpin,
    required this.onForward,
    required this.onSaveMessage,
    required this.onUnsaveMessage,
    required this.onJumpToReplyQuote,
    required this.onAvatarTap,
    required this.onVerifyIdentity,
    required this.onImageTap,
    required this.isMessageSaved,
    required this.onSayHi,
  });

  // ---- Pure helpers (formerly on _ChatPanelState) -----------------------

  static bool _isSystemTimelineMessage(ChatMessage msg) {
    return msg.content.startsWith('[system:');
  }

  static bool _withinGroupingWindow(String ts1, String ts2) {
    try {
      final dt1 = DateTime.parse(ts1);
      final dt2 = DateTime.parse(ts2);
      return dt2.difference(dt1).inMinutes.abs() < 5;
    } catch (_) {
      return false;
    }
  }

  static bool _differentDay(String ts1, String ts2) {
    try {
      final d1 = DateTime.parse(ts1);
      final d2 = DateTime.parse(ts2);
      return d1.year != d2.year || d1.month != d2.month || d1.day != d2.day;
    } catch (_) {
      return false;
    }
  }

  // ---- Build helpers -----------------------------------------------------

  Widget _buildMessageAtIndex(BuildContext context, WidgetRef ref, int i) {
    final msg = messages[i];

    if (_isSystemTimelineMessage(msg)) {
      return SystemTimelineMessage(msg: msg);
    }

    final needsDateDivider =
        i == 0 || _differentDay(messages[i - 1].timestamp, msg.timestamp);

    final showHeader =
        i == 0 ||
        messages[i - 1].fromUserId != msg.fromUserId ||
        !_withinGroupingWindow(messages[i - 1].timestamp, msg.timestamp);

    final isLastInGroup =
        i == messages.length - 1 ||
        messages[i + 1].fromUserId != msg.fromUserId;

    final senderAvatarUrl = memberAvatars[msg.fromUserId];
    final isHighlighted = highlightedMessageId == msg.id;

    final showUnreadDivider = unreadBoundaryMessageId == msg.id;

    final messageKey = messageKeys.putIfAbsent(msg.id, () => GlobalKey());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (needsDateDivider) DateDivider(timestamp: msg.timestamp),
        if (showUnreadDivider) UnreadDivider(count: unreadBoundaryCount),
        AnimatedContainer(
          key: messageKey,
          duration: const Duration(milliseconds: 400),
          color: isHighlighted
              ? context.accent.withValues(alpha: 0.15)
              : Colors.transparent,
          child: MessageItem(
            message: msg,
            showHeader: showHeader,
            isLastInGroup: isLastInGroup,
            myUserId: myUserId,
            serverUrl: serverUrl,
            authToken: authToken,
            mediaTicket: mediaTicket,
            senderAvatarUrl: senderAvatarUrl,
            layout: ref.watch(messageLayoutProvider),
            hideUndecryptable: ref
                .watch(accessibilityProvider)
                .hideUndecryptable,
            onReactionTap: onReactionTap,
            onReactionSelect: (message, emoji) {
              final alreadyReacted = message.reactions.any(
                (r) => r.emoji == emoji && r.userId == myUserId,
              );
              onToggleReaction(message, emoji, alreadyReacted);
            },
            onMoreReactions: onMoreReactions,
            onDelete: msg.status == MessageStatus.failed
                ? onDeleteFailed
                : onConfirmDelete,
            onRetry: msg.status == MessageStatus.failed ? onRetryMessage : null,
            // #582: editing on an encrypted conversation would broadcast
            // plaintext to every member, breaking E2E. Until per-device
            // ciphertext fanout for edits ships, suppress the affordance
            // entirely on encrypted conversations. Server enforces with 409.
            onEdit: conv.isEncrypted ? null : onEnterEditMode,
            onReply: onReply,
            onViewThread: onOpenThread,
            onPin: onPin,
            onUnpin: onUnpin,
            onForward: onForward,
            isSaved: savedIds.contains(msg.id) || isMessageSaved(msg.id),
            onSave: onSaveMessage,
            onUnsave: onUnsaveMessage,
            onTapReplyQuote: onJumpToReplyQuote,
            onAvatarTap: onAvatarTap,
            onVerifyIdentity: onVerifyIdentity,
            onImageTap: onImageTap,
          ),
        ),
      ],
    );
  }

  Widget _buildMessageListView(BuildContext context, WidgetRef ref) {
    return Scrollbar(
      controller: scrollController,
      thumbVisibility: defaultTargetPlatform != TargetPlatform.iOS,
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: messages.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            if (chatState.conversationHasMore(conv.id, channelId: channelId)) {
              return SizedBox(
                height: 48,
                child: chatState.isLoadingHistory(conv.id, channelId: channelId)
                    ? const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const SizedBox.shrink(),
              );
            }
            return const SizedBox(height: 8);
          }
          return _buildMessageAtIndex(context, ref, index - 1);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Widget child;
    if (messages.isEmpty && isLoadingHistory) {
      child = const SingleChildScrollView(
        key: ValueKey('skeleton'),
        child: MessageListSkeleton(),
      );
    } else if (messages.isEmpty && !isLoadingHistory) {
      child = KeyedSubtree(
        key: const ValueKey('empty'),
        child: EmptyMessagePlaceholder(
          displayName: displayName,
          onSayHi: onSayHi,
        ),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey('list'),
        child: _buildMessageListView(context, ref),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }
}
