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
  final String? editedAt;
  final bool isEncrypted;

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
    this.editedAt,
    this.isEncrypted = false,
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

    final id = (json['message_id'] ?? json['id'] ?? '').toString();
    final fromUserId = (json['from_user_id'] ?? json['sender_id'] ?? '')
        .toString();
    final fromUsername =
        (json['from_username'] ?? json['sender_username'] ?? 'Unknown')
            .toString();
    final conversationId = (json['conversation_id'] ?? '').toString();
    final content = (json['content'] ?? '').toString();
    final timestamp =
        (json['timestamp'] ??
                json['created_at'] ??
                DateTime.now().toIso8601String())
            .toString();

    return ChatMessage(
      id: id,
      fromUserId: fromUserId,
      fromUsername: fromUsername,
      conversationId: conversationId,
      content: content,
      timestamp: timestamp,
      isMine: fromUserId == myUserId,
      status: MessageStatus.sent,
      reactions: reactionsList,
      editedAt: json['edited_at'] as String?,
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
    String? editedAt,
    bool? isEncrypted,
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
      editedAt: editedAt ?? this.editedAt,
      isEncrypted: isEncrypted ?? this.isEncrypted,
    );
  }
}
