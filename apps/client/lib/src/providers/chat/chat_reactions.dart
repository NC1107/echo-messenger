part of 'chat_provider.dart';

/// Reaction add/remove for the chat notifier. Pure list-rewrite over the
/// affected conversation; no timer or reply-count bookkeeping involved.
///
/// Mixed into [Chat]. Mutations preserve the dedup `_messageIdIndex` by
/// leaving it untouched — reactions don't change message IDs.
mixin ChatReactionsMixin on Notifier<ChatState> {
  /// Add a reaction to a message.
  void addReaction(String conversationId, Reaction reaction) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == reaction.messageId) {
        final reactions = List<Reaction>.from(msg.reactions);
        // Remove existing reaction from same user with same emoji (toggle)
        reactions.removeWhere(
          (r) => r.userId == reaction.userId && r.emoji == reaction.emoji,
        );
        reactions.add(reaction);
        return msg.copyWith(reactions: reactions);
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

  /// Remove a reaction from a message.
  void removeReaction(
    String conversationId,
    String messageId,
    String userId,
    String emoji,
  ) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        final reactions = List<Reaction>.from(msg.reactions);
        reactions.removeWhere((r) => r.userId == userId && r.emoji == emoji);
        return msg.copyWith(reactions: reactions);
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
}
