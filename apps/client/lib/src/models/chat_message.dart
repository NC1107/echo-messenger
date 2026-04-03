import 'reaction.dart';

enum MessageStatus { sending, sent, delivered, read, failed }

class ChatMessage {
  final String id;
  final String fromUserId;
  final String fromUsername;
  final String conversationId;
  final String? channelId;
  final String content;
  final String timestamp;
  final bool isMine;
  final MessageStatus status;
  final List<Reaction> reactions;
  final String? editedAt;
  final bool isEncrypted;
  final String? replyToId;
  final String? replyToContent;
  final String? replyToUsername;

  const ChatMessage({
    required this.id,
    required this.fromUserId,
    required this.fromUsername,
    required this.conversationId,
    this.channelId,
    required this.content,
    required this.timestamp,
    required this.isMine,
    this.status = MessageStatus.sent,
    this.reactions = const [],
    this.editedAt,
    this.isEncrypted = false,
    this.replyToId,
    this.replyToContent,
    this.replyToUsername,
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
    final channelId = (json['channel_id'] as String?)?.trim();
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
      channelId: (channelId == null || channelId.isEmpty) ? null : channelId,
      content: content,
      timestamp: timestamp,
      isMine: fromUserId == myUserId,
      status: MessageStatus.sent,
      reactions: reactionsList,
      editedAt: json['edited_at'] as String?,
      replyToId: json['reply_to_id'] as String?,
      replyToContent: json['reply_to_content'] as String?,
      replyToUsername: json['reply_to_username'] as String?,
    );
  }

  ChatMessage copyWith({
    String? id,
    String? fromUserId,
    String? fromUsername,
    String? conversationId,
    String? channelId,
    String? content,
    String? timestamp,
    bool? isMine,
    MessageStatus? status,
    List<Reaction>? reactions,
    String? editedAt,
    bool? isEncrypted,
    String? replyToId,
    String? replyToContent,
    String? replyToUsername,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      fromUserId: fromUserId ?? this.fromUserId,
      fromUsername: fromUsername ?? this.fromUsername,
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isMine: isMine ?? this.isMine,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
      editedAt: editedAt ?? this.editedAt,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      replyToId: replyToId ?? this.replyToId,
      replyToContent: replyToContent ?? this.replyToContent,
      replyToUsername: replyToUsername ?? this.replyToUsername,
    );
  }
}
