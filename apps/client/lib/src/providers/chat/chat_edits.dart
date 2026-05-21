part of 'chat_provider.dart';

/// Post-send mutations on existing messages: edits, soft-deletes,
/// read-receipt sweeps, pin toggles, and the forward helper. None of
/// these allocate a new pending-send slot, so they don't touch
/// `_sendTimeouts` or the optimistic reply-count bookkeeping that the
/// send/retry path uses.
///
/// Mixed into [Chat]. The dedup `_messageIdIndex` is rebuilt incrementally
/// only by [deleteMessage]; the other helpers leave message IDs untouched.
mixin ChatEditsMixin on Notifier<ChatState> {
  /// Mark all of my sent/delivered messages in a conversation as read.
  void markConversationRead(String conversationId) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.isMine &&
          (msg.status == MessageStatus.sent ||
              msg.status == MessageStatus.delivered)) {
        return msg.copyWith(status: MessageStatus.read);
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );
  }

  /// Delete a message from local state.
  void deleteMessage(String conversationId, String messageId) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.where((msg) => msg.id != messageId).toList();

    // Remove the deleted ID from the index incrementally.
    final existingIds = state._messageIdIndex[conversationId] ?? const {};
    final newIds = Set<String>.from(existingIds)..remove(messageId);

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
      messageIdIndex: {...state._messageIdIndex, conversationId: newIds},
    );
  }

  /// Update a message's content and set editedAt.
  void editMessage(
    String conversationId,
    String messageId,
    String newContent, {
    String? editedAt,
  }) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(
          content: newContent,
          editedAt: editedAt ?? DateTime.now().toIso8601String(),
        );
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );

    // Persist the edit to the local Hive cache so it survives app restart.
    final edited = updated.where((m) => m.id == messageId).toList();
    if (edited.isNotEmpty) {
      MessageCache.cacheMessages(conversationId, edited);
    }
  }

  /// Update a message's pin state in local state.
  void updateMessagePin(
    String conversationId,
    String messageId,
    String? pinnedById,
    DateTime? pinnedAt,
  ) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(pinnedById: pinnedById, pinnedAt: pinnedAt);
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );
  }

  /// Forward a message to a different conversation.
  ///
  /// Prepends "[Forwarded] " to the content and delegates the actual wire
  /// send to [sender], which is supplied by the caller to avoid a circular
  /// dependency (websocket_provider already imports chat_provider).
  Future<void> forwardMessage(
    String messageContent,
    String targetConversationId,
    Future<void> Function(String forwardedContent) sender,
  ) async {
    final forwarded = '[Forwarded] $messageContent';
    await sender(forwarded);
  }
}
