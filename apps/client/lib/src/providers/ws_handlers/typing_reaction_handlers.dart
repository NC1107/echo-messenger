part of '../ws_message_handler.dart';

extension TypingReactionHandlersOn on WsMessageHandler {
  void _handleTyping(Map<String, dynamic> json, String myUserId) {
    final conversationId = json['conversation_id'] as String;
    final channelId = json['channel_id'] as String?;
    final fromUserId =
        (json['from_user_id'] as String?) ?? (json['user_id'] as String?) ?? '';
    final fromUsername = json['from_username'] as String? ?? 'Someone';

    // Don't show own typing indicator
    if (fromUserId == myUserId) return;

    final typingKey = '$conversationId:${channelId ?? ''}';
    final updatedTyping = Map<String, Map<String, DateTime>>.from(
      _state.typingUsers,
    );
    final conversationTyping = Map<String, DateTime>.from(
      updatedTyping[typingKey] ?? {},
    );
    conversationTyping[fromUsername] = DateTime.now();
    updatedTyping[typingKey] = conversationTyping;

    _state = _state.copyWith(typingUsers: updatedTyping);
  }

  void _handleReaction(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final reaction = Reaction.fromJson(json);
    ref.read(chatProvider.notifier).addReaction(conversationId, reaction);
  }

  void _handleRemoveReaction(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    final userId = json['user_id'] as String;
    final emoji = json['emoji'] as String;
    ref
        .read(chatProvider.notifier)
        .removeReaction(conversationId, messageId, userId, emoji);
  }

  void _handleDelivered(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    ref
        .read(chatProvider.notifier)
        .updateMessageStatus(
          conversationId,
          messageId,
          MessageStatus.delivered,
        );
  }

  void _handleReadReceipt(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    ref.read(chatProvider.notifier).markConversationRead(conversationId);
  }
}
