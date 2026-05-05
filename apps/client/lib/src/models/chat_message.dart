import 'reaction.dart';

/// Sentinel value used in [ChatMessage.copyWith] to distinguish between
/// "not provided" and "explicitly set to null" for nullable fields.
const _sentinel = Object();

enum MessageStatus { sending, sent, delivered, read, failed }

/// Parse a [MessageStatus] from its [name] string (Hive cache round-trip).
/// Falls back to [MessageStatus.sent] for unknown or absent values so that
/// server-originated JSON (which has no status field) degrades gracefully.
MessageStatus _statusFromJson(String? raw) {
  if (raw == null) return MessageStatus.sent;
  return MessageStatus.values.firstWhere(
    (s) => s.name == raw,
    orElse: () => MessageStatus.sent,
  );
}

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
  final int replyCount;
  final String? pinnedById;
  final DateTime? pinnedAt;
  final DateTime? expiresAt;

  /// The original plaintext for failed messages, enabling retry.
  /// When a message fails to send, [content] holds the user-facing error
  /// reason while [failedContent] preserves the actual message text.
  final String? failedContent;

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
    this.replyCount = 0,
    this.pinnedById,
    this.pinnedAt,
    this.expiresAt,
    this.failedContent,
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
    var fromUserId = (json['from_user_id'] ?? json['sender_id'] ?? '')
        .toString();
    var fromUsername =
        (json['from_username'] ?? json['sender_username'] ?? 'Unknown')
            .toString();
    final conversationId = (json['conversation_id'] ?? '').toString();
    final channelId = (json['channel_id'] as String?)?.trim();
    var content = (json['content'] ?? '').toString();

    // Translate raw `__system__:...` sentinels persisted server-side into
    // proper system events so historical loads render as in-chat pills
    // (#663). Without this, the WS path correctly produces system events,
    // but reloading the app or opening the conversation for the first
    // time would show the literal sentinel as a regular message bubble.
    if (content.startsWith('__system__:')) {
      final translated = _translateSystemSentinel(content);
      if (translated != null) {
        content = translated;
        fromUserId = systemUserId;
        fromUsername = 'System';
      }
    }
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
      status: _statusFromJson(json['status'] as String?),
      reactions: reactionsList,
      editedAt: json['edited_at'] as String?,
      replyToId: json['reply_to_id'] as String?,
      replyToContent: json['reply_to_content'] as String?,
      replyToUsername: json['reply_to_username'] as String?,
      replyCount: (json['reply_count'] as int?) ?? 0,
      pinnedById: pinnedByIdRaw,
      pinnedAt: pinnedAtRaw != null ? DateTime.tryParse(pinnedAtRaw) : null,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
    );
  }

  /// Convert a `__system__:...` sentinel into a human-readable event line.
  /// Returns null if the sentinel is malformed or unknown so the caller
  /// can leave the message untouched.
  static String? _translateSystemSentinel(String sentinel) {
    const joinedTag = '__system__:member_joined:';
    if (sentinel.startsWith(joinedTag)) {
      final rest = sentinel.substring(joinedTag.length);
      final colonIdx = rest.indexOf(':');
      final username = colonIdx >= 0 ? rest.substring(colonIdx + 1) : rest;
      if (username.isEmpty) return null;
      return '$username joined the group';
    }
    return null;
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
      'reply_count': replyCount,
      'pinned_by_id': pinnedById,
      'pinned_at': pinnedAt?.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'reactions': reactions.map((r) => r.toJson()).toList(),
      'status': status.name,
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
    int? replyCount,
    Object? pinnedById = _sentinel,
    Object? pinnedAt = _sentinel,
    Object? expiresAt = _sentinel,
    Object? failedContent = _sentinel,
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
      replyCount: replyCount ?? this.replyCount,
      pinnedById: pinnedById == _sentinel
          ? this.pinnedById
          : pinnedById as String?,
      pinnedAt: pinnedAt == _sentinel ? this.pinnedAt : pinnedAt as DateTime?,
      expiresAt: expiresAt == _sentinel
          ? this.expiresAt
          : expiresAt as DateTime?,
      failedContent: failedContent == _sentinel
          ? this.failedContent
          : failedContent as String?,
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
            replyCount == other.replyCount &&
            pinnedById == other.pinnedById &&
            pinnedAt == other.pinnedAt &&
            expiresAt == other.expiresAt &&
            failedContent == other.failedContent;
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
    replyCount,
    pinnedById,
    pinnedAt,
    expiresAt,
    failedContent,
  );
}
