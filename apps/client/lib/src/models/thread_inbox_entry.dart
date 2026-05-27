/// One row of the cross-group threads inbox.
///
/// Mirrors the server's `ThreadInboxEntry` (apps/server/src/db/threads.rs)
/// and is returned from `GET /api/threads/inbox` sorted newest-reply-first.
library;

import 'package:flutter/foundation.dart' show immutable;

@immutable
class ThreadInboxEntry {
  final String threadRootId;
  final String conversationId;
  final String? channelId;
  final String parentSenderUsername;
  final String parentExcerpt;
  final DateTime lastReplyAt;
  final String lastReplyExcerpt;
  final String lastReplySenderUsername;
  final int replyCount;
  final int unreadCount;

  bool get isUnread => unreadCount > 0;

  const ThreadInboxEntry({
    required this.threadRootId,
    required this.conversationId,
    required this.channelId,
    required this.parentSenderUsername,
    required this.parentExcerpt,
    required this.lastReplyAt,
    required this.lastReplyExcerpt,
    required this.lastReplySenderUsername,
    required this.replyCount,
    required this.unreadCount,
  });

  factory ThreadInboxEntry.fromJson(Map<String, dynamic> json) {
    return ThreadInboxEntry(
      threadRootId: json['thread_root_id'] as String,
      conversationId: json['conversation_id'] as String,
      channelId: json['channel_id'] as String?,
      parentSenderUsername: json['parent_sender_username'] as String,
      parentExcerpt: json['parent_excerpt'] as String,
      lastReplyAt: DateTime.parse(json['last_reply_at'] as String),
      lastReplyExcerpt: json['last_reply_excerpt'] as String,
      lastReplySenderUsername: json['last_reply_sender_username'] as String,
      replyCount: (json['reply_count'] as num).toInt(),
      unreadCount: (json['unread_count'] as num).toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThreadInboxEntry &&
          threadRootId == other.threadRootId &&
          lastReplyAt == other.lastReplyAt &&
          replyCount == other.replyCount &&
          unreadCount == other.unreadCount;

  @override
  int get hashCode =>
      Object.hash(threadRootId, lastReplyAt, replyCount, unreadCount);
}
