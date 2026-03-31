import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';

class ChatState {
  final Map<String, List<ChatMessage>> messagesByPeer;

  const ChatState({this.messagesByPeer = const {}});

  List<ChatMessage> messagesFor(String peerUserId) {
    return messagesByPeer[peerUserId] ?? [];
  }

  ChatState withMessage(String peerKey, ChatMessage msg) {
    final updated = Map<String, List<ChatMessage>>.from(messagesByPeer);
    updated[peerKey] = [...(updated[peerKey] ?? []), msg];
    return ChatState(messagesByPeer: updated);
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier() : super(const ChatState());

  void addMessage(ChatMessage msg) {
    final peerKey = msg.isMine
        ? _findPeerForConversation(msg.conversationId) ?? msg.fromUserId
        : msg.fromUserId;
    state = state.withMessage(peerKey, msg);
  }

  void addOptimistic(String peerUserId, String content, String myUserId) {
    final msg = ChatMessage(
      id: 'pending_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: myUserId,
      fromUsername: 'You',
      conversationId: '',
      content: content,
      timestamp: DateTime.now().toIso8601String(),
      isMine: true,
    );
    state = state.withMessage(peerUserId, msg);
  }

  void confirmSent(String messageId, String conversationId, String timestamp) {
    // Optimistic messages are already displayed.
    // Could update the pending message with real ID/timestamp if needed.
  }

  String? _findPeerForConversation(String conversationId) {
    // For now, we don't track this mapping.
    return null;
  }

  void clear() {
    state = const ChatState();
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier();
});
