/// One row of the "Threads" sidebar: a parent message whose thread the user
/// has participated in (authored a reply, or been mentioned in a reply).
///
/// Mirrors the server `ParticipatedThreadDto` shape returned by
/// `GET /api/threads/participated`.
class ParticipatedThread {
  final String parentMessageId;
  final String conversationId;
  final String? channelId;

  /// Truncated parent text. On encrypted conversations this is ciphertext;
  /// callers may try to decrypt and fall back to `'[Encrypted]'`.
  final String? parentPreview;
  final String? parentSenderUsername;

  final int replyCount;

  /// Coarse approximation today (per-conversation `last_read_at`); revisit
  /// when per-thread read state lands (#449).
  final int unreadReplyCount;

  /// Most-recent reply timestamp (ISO 8601 from the server).
  final DateTime lastReplyAt;
  final String? lastReplySenderUsername;

  const ParticipatedThread({
    required this.parentMessageId,
    required this.conversationId,
    this.channelId,
    this.parentPreview,
    this.parentSenderUsername,
    required this.replyCount,
    required this.unreadReplyCount,
    required this.lastReplyAt,
    this.lastReplySenderUsername,
  });

  factory ParticipatedThread.fromJson(Map<String, dynamic> json) {
    return ParticipatedThread(
      parentMessageId: json['parent_message_id'] as String,
      conversationId: json['conversation_id'] as String,
      channelId: json['channel_id'] as String?,
      parentPreview: json['parent_preview'] as String?,
      parentSenderUsername: json['parent_sender_username'] as String?,
      replyCount: (json['reply_count'] as num).toInt(),
      unreadReplyCount: (json['unread_reply_count'] as num).toInt(),
      lastReplyAt: DateTime.parse(json['last_reply_at'] as String),
      lastReplySenderUsername: json['last_reply_sender_username'] as String?,
    );
  }
}
