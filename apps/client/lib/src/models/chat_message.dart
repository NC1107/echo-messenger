import 'reaction.dart';

/// Sentinel value used in [ChatMessage.copyWith] to distinguish between
/// "not provided" and "explicitly set to null" for nullable fields.
const _sentinel = Object();

enum MessageStatus { sending, sent, delivered, read, failed }

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class ChatMessage {
  /// System event messages use this as fromUserId.
  static const systemUserId = '__system__';

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
  final String? pinnedById;
  final DateTime? pinnedAt;

  /// True if this is a system event (call history, key reset, etc.)
  bool get isSystemEvent => fromUserId == systemUserId;

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
    this.pinnedById,
    this.pinnedAt,
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

    final pinnedByIdRaw = json['pinned_by_id'] as String?;
    final pinnedAtRaw = json['pinned_at'] as String?;

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
      pinnedById: pinnedByIdRaw,
      pinnedAt: pinnedAtRaw != null ? DateTime.tryParse(pinnedAtRaw) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'message_id': id,
      'from_user_id': fromUserId,
      'from_username': fromUsername,
      'conversation_id': conversationId,
      'channel_id': channelId,
      'content': content,
      'created_at': timestamp,
      'is_encrypted': isEncrypted,
      'edited_at': editedAt,
      'reply_to_id': replyToId,
      'reply_to_content': replyToContent,
      'reply_to_username': replyToUsername,
      'pinned_by_id': pinnedById,
      'pinned_at': pinnedAt?.toIso8601String(),
      'reactions': reactions.map((r) => r.toJson()).toList(),
    };
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
    Object? pinnedById = _sentinel,
    Object? pinnedAt = _sentinel,
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
      pinnedById: pinnedById == _sentinel
          ? this.pinnedById
          : pinnedById as String?,
      pinnedAt: pinnedAt == _sentinel ? this.pinnedAt : pinnedAt as DateTime?,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ChatMessage &&
            id == other.id &&
            fromUserId == other.fromUserId &&
            fromUsername == other.fromUsername &&
            conversationId == other.conversationId &&
            channelId == other.channelId &&
            content == other.content &&
            timestamp == other.timestamp &&
            isMine == other.isMine &&
            status == other.status &&
            _listEquals(reactions, other.reactions) &&
            editedAt == other.editedAt &&
            isEncrypted == other.isEncrypted &&
            replyToId == other.replyToId &&
            replyToContent == other.replyToContent &&
            replyToUsername == other.replyToUsername &&
            pinnedById == other.pinnedById &&
            pinnedAt == other.pinnedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    fromUserId,
    fromUsername,
    conversationId,
    channelId,
    content,
    timestamp,
    isMine,
    status,
    Object.hashAll(reactions),
    editedAt,
    isEncrypted,
    replyToId,
    replyToContent,
    replyToUsername,
    pinnedById,
    pinnedAt,
  );
}
