part of 'conversations_provider.dart';

// ---------------------------------------------------------------------------
// WebSocket event handlers for ConversationsNotifier.
//
// Extracted from conversations_provider.dart (#712). These methods handle
// real-time WS events and mutate local state without making HTTP calls.
// ---------------------------------------------------------------------------

mixin _ConversationsWsHandlersMixin on StateNotifier<ConversationsState> {
  // Dependencies implemented by ConversationsNotifier.
  Map<String, String> get _decryptedPreviews;
  void _updateTabBadge();
  Future<void> loadConversations();

  /// Update a conversation when a new message is received.
  ///
  /// Set [incrementUnread] to false for the sender's own messages so the
  /// unread badge is not bumped for messages the user just sent.
  void onNewMessage({
    required String conversationId,
    required String content,
    required String timestamp,
    required String senderUsername,
    bool incrementUnread = true,
  }) {
    // System sentinel messages (#663) must not appear in the conversation
    // preview or increment the unread badge.
    if (content.startsWith('__system__:')) return;

    // Cache the decrypted preview (content passed here is already decrypted
    // by the websocket provider). Guard against failure sentinels (#664).
    if (!MessageCache.failureSentinels.contains(content)) {
      _decryptedPreviews[conversationId] = content;
    }

    final conversations = state.conversations;
    final index = conversations.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      final conv = conversations[index];
      final updatedConv = conv.copyWith(
        lastMessage: content,
        lastMessageTimestamp: timestamp,
        lastMessageSender: senderUsername,
        unreadCount: incrementUnread ? conv.unreadCount + 1 : conv.unreadCount,
      );

      // Build new list updating only the changed conversation and moving
      // it to the top, avoiding a full List.from() copy when possible.
      final updated = [
        updatedConv,
        for (var i = 0; i < conversations.length; i++)
          if (i != index) conversations[i],
      ];

      state = state.copyWith(conversations: updated);
      _updateTabBadge();
    } else {
      // New conversation we don't have locally -- reload from server
      loadConversations();
    }
  }

  /// Update the conversation preview if an edited message was the last one.
  void onMessageEdited({
    required String conversationId,
    required String newContent,
  }) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);
    if (index >= 0) {
      final conv = updated[index];
      // Only update preview -- we can't cheaply tell if this was the last
      // message, but updating the preview is harmless either way since the
      // next real message will overwrite it.
      updated[index] = conv.copyWith(lastMessage: newContent);
      if (!MessageCache.failureSentinels.contains(newContent)) {
        _decryptedPreviews[conversationId] = newContent;
      }
      state = state.copyWith(conversations: updated);
    }
  }

  /// Store a decrypted preview for a conversation so the conversation list
  /// shows the decrypted text instead of "Encrypted message".
  ///
  /// Silently ignores failure-sentinel strings so a temporary decrypt failure
  /// never overwrites a good cached preview and never surfaces in the
  /// conversation list (#664).
  void updateDecryptedPreview(String conversationId, String content) {
    if (MessageCache.failureSentinels.contains(content)) return;
    _decryptedPreviews[conversationId] = content;
  }

  /// Update the encryption flag for a conversation locally.
  void updateEncryption(String conversationId, bool isEncrypted) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);
    if (index >= 0) {
      updated[index] = updated[index].copyWith(isEncrypted: isEncrypted);
      // Clear cached plaintext preview so it doesn't leak after toggling
      // encryption on. The next message will repopulate the preview.
      _decryptedPreviews.remove(conversationId);
      state = state.copyWith(conversations: updated);
    }
  }

  /// Append a new member to a group conversation's member list in-place.
  ///
  /// Called by the WS `member_added` handler (#660) so the members panel
  /// updates without a full server round-trip. Silently no-ops when the
  /// conversation is unknown or the member is already present.
  void addGroupMember(String conversationId, ConversationMember member) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);
    if (index < 0) return;
    final conv = updated[index];
    final alreadyPresent = conv.members.any((m) => m.userId == member.userId);
    if (alreadyPresent) return;
    updated[index] = conv.copyWith(members: [...conv.members, member]);
    state = state.copyWith(conversations: updated);
  }
}
