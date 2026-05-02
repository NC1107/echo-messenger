part of '../ws_message_handler.dart';

extension VoiceHandlersOn on WsMessageHandler {
  void _handleVoiceSignal(Map<String, dynamic> json) {
    voiceSignalController.add(json);
  }

  void _handleCallStarted(Map<String, dynamic> json) {
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';

    ref
        .read(chatProvider.notifier)
        .addSystemEvent(conversationId, '$fromUsername started a voice call');

    // Show notification
    final myUserId = ref.read(authProvider).userId ?? '';
    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    NotificationService().showMessageNotification(
      senderUsername: fromUsername,
      body: 'Started a voice call',
      conversationId: conversationId,
      conversationName: conv?.displayName(myUserId),
      isMuted: conv?.isMuted ?? false,
    );
  }
}
