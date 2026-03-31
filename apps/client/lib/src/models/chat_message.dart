class ChatMessage {
  final String id;
  final String fromUserId;
  final String fromUsername;
  final String conversationId;
  final String content;
  final String timestamp;
  final bool isMine;

  const ChatMessage({
    required this.id,
    required this.fromUserId,
    required this.fromUsername,
    required this.conversationId,
    required this.content,
    required this.timestamp,
    required this.isMine,
  });

  factory ChatMessage.fromServerJson(
      Map<String, dynamic> json, String myUserId) {
    return ChatMessage(
      id: json['message_id'] as String,
      fromUserId: json['from_user_id'] as String,
      fromUsername: json['from_username'] as String,
      conversationId: json['conversation_id'] as String,
      content: json['content'] as String,
      timestamp: json['timestamp'] as String,
      isMine: json['from_user_id'] == myUserId,
    );
  }
}
