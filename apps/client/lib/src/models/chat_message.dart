import 'reaction.dart';

enum MessageStatus { sending, sent, delivered, failed }

class ChatMessage {
  final String id;
  final String fromUserId;
  final String fromUsername;
  final String conversationId;
  final String content;
  final String timestamp;
  final bool isMine;
  final MessageStatus status;
  final List<Reaction> reactions;

  const ChatMessage({
    required this.id,
    required this.fromUserId,
    required this.fromUsername,
    required this.conversationId,
    required this.content,
    required this.timestamp,
    required this.isMine,
    this.status = MessageStatus.sent,
    this.reactions = const [],
  });

  factory ChatMessage.fromServerJson(
    Map<String, dynamic> json,
    String myUserId,
  ) {
    final reactionsList =
        (json['reactions'] as List?)
            ?.map((e) => Reaction.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return ChatMessage(
      id: json['message_id'] as String,
      fromUserId: json['from_user_id'] as String,
      fromUsername: json['from_username'] as String,
      conversationId: json['conversation_id'] as String,
      content: json['content'] as String,
      timestamp: json['timestamp'] as String,
      isMine: json['from_user_id'] == myUserId,
      status: MessageStatus.sent,
      reactions: reactionsList,
    );
  }

  ChatMessage copyWith({
    String? id,
    String? fromUserId,
    String? fromUsername,
    String? conversationId,
    String? content,
    String? timestamp,
    bool? isMine,
    MessageStatus? status,
    List<Reaction>? reactions,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      fromUserId: fromUserId ?? this.fromUserId,
      fromUsername: fromUsername ?? this.fromUsername,
      conversationId: conversationId ?? this.conversationId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isMine: isMine ?? this.isMine,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
    );
  }
}
