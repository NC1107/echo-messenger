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

/// TD-79: lazy `DateTime.parse` cache keyed by `ChatMessage` identity. Used
/// only by [ChatMessage.parsedTimestamp]; declared outside the class so the
/// class stays `const`-constructible.
final Expando<DateTime> _parsedTimestampCache = Expando<DateTime>(
  'ChatMessage.parsedTimestamp',
);

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

  /// Threads M2 (docs/threads-architecture.md): when non-null this message
  /// belongs to the thread rooted at that id and is filtered out of the
  /// main channel timeline. Old servers omit the field — treat as null
  /// (back-compat: legacy replies stay in the main timeline).
  final String? threadRootId;

  final int replyCount;

  /// Truncated content of the most-recent reply to this message, used for
  /// the Slack-style inline preview row under the parent (#423). Only
  /// populated by history loads (`get_messages`); the WS real-time path
  /// keeps this null and relies on `message_reply_added` to bump the
  /// count. `null` when there are no replies.
  final String? latestReplyPreview;

  /// Timestamp of the most-recent reply. Populated by history loads;
  /// drives the "Xm ago" label on the thread indicator chip.
  final DateTime? lastReplyAt;

  /// Usernames of up to 3 distinct most-recent repliers, newest first.
  /// Populated by history loads so the thread chip can render face stacks
  /// inline; never larger than 3.
  final List<String> recentReplierUsernames;
  final String? pinnedById;
  final DateTime? pinnedAt;
  final DateTime? expiresAt;

  /// The original plaintext for failed messages, enabling retry.
  /// When a message fails to send, [content] holds the user-facing error
  /// reason while [failedContent] preserves the actual message text.
  final String? failedContent;

  /// True if this is a system event (call history, key reset, etc.)
  bool get isSystemEvent => fromUserId == systemUserId;

  /// TD-79: lazily-parsed [timestamp] used by message-grouping helpers in
  /// `chat_message_list.dart`. Each `_buildMessageAtIndex` invocation
  /// previously called `DateTime.parse` against both the prior and next
  /// neighbour's `String` timestamp — for a 30-row viewport that's ~120
  /// parses per repaint. Caching the parsed value on the message itself
  /// turns repeated parses into a single shared instance.
  ///
  /// The cache lives in a static [Expando] so `ChatMessage` stays a
  /// `const`-constructible value class; the parse only fires the first
  /// time any consumer asks for it and the result is keyed by message
  /// identity. Falls back to a sentinel epoch on parse failure so callers
  /// don't need to handle a nullable.
  DateTime get parsedTimestamp {
    final cached = _parsedTimestampCache[this];
    if (cached != null) return cached;
    final parsed =
        DateTime.tryParse(timestamp) ?? DateTime.fromMillisecondsSinceEpoch(0);
    _parsedTimestampCache[this] = parsed;
    return parsed;
  }

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
    this.threadRootId,
    this.replyCount = 0,
    this.latestReplyPreview,
    this.lastReplyAt,
    this.recentReplierUsernames = const [],
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
            ?.map((e) => Reaction.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList() ??
        [];

    final id = (json['id'] ?? json['message_id'] ?? '').toString();
    var fromUserId = (json['sender_id'] ?? json['from_user_id'] ?? '')
        .toString();
    var fromUsername =
        (json['sender_username'] ?? json['from_username'] ?? 'Unknown')
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
      final translated = translateSystemSentinel(content, myUserId: myUserId);
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
      threadRootId: json['thread_root_id'] as String?,
      replyCount: (json['reply_count'] as int?) ?? 0,
      latestReplyPreview: json['last_reply_snippet'] as String?,
      lastReplyAt: json['last_reply_at'] != null
          ? DateTime.tryParse(json['last_reply_at'] as String)
          : null,
      recentReplierUsernames:
          (json['recent_replier_usernames'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
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
  ///
  /// Pass [myUserId] to get first-person phrasing ("You joined") when the
  /// acting user is the current user.
  ///
  /// Implementation is a dispatch over the known event tags; each branch
  /// delegates to a small typed helper to keep cognitive complexity below
  /// the SonarQube S3776 budget of 15.
  static String? translateSystemSentinel(String sentinel, {String? myUserId}) {
    const joinedTag = '__system__:member_joined:';
    if (sentinel.startsWith(joinedTag)) {
      return _formatActiveEvent(
        sentinel,
        joinedTag,
        myUserId,
        verbPhrase: 'joined the group',
      );
    }

    const leftTag = '__system__:member_left:';
    if (sentinel.startsWith(leftTag)) {
      return _formatActiveEvent(
        sentinel,
        leftTag,
        myUserId,
        verbPhrase: 'left the group',
      );
    }

    const removedTag = '__system__:member_removed:';
    if (sentinel.startsWith(removedTag)) {
      return _formatPassiveEvent(
        sentinel,
        removedTag,
        myUserId,
        verbPhrase: 'removed from the group',
      );
    }

    const bannedTag = '__system__:member_banned:';
    if (sentinel.startsWith(bannedTag)) {
      return _formatPassiveEvent(
        sentinel,
        bannedTag,
        myUserId,
        verbPhrase: 'banned from the group',
      );
    }

    return null;
  }

  /// Parse the `<uuid>:<username>` tail that follows [tag] in [sentinel].
  /// Returns null when the sentinel is malformed (missing colon or empty
  /// username).
  static (String, String)? _parseUuidUsername(String sentinel, String tag) {
    final rest = sentinel.substring(tag.length);
    final colonIdx = rest.indexOf(':');
    if (colonIdx < 0) return null;
    final uuid = rest.substring(0, colonIdx);
    final username = rest.substring(colonIdx + 1);
    if (username.isEmpty) return null;
    return (uuid, username);
  }

  /// Format an "active-voice" event ("X joined the group", "You left the
  /// group"). Returns null when the sentinel payload is malformed.
  static String? _formatActiveEvent(
    String sentinel,
    String tag,
    String? myUserId, {
    required String verbPhrase,
  }) {
    final parts = _parseUuidUsername(sentinel, tag);
    if (parts == null) return null;
    final (uuid, username) = parts;
    final subject = _subjectFor(uuid, username, myUserId, selfPronoun: 'You');
    return '$subject $verbPhrase';
  }

  /// Format a "passive-voice" event ("X was removed from the group", "You
  /// were banned from the group"). Returns null when the sentinel payload
  /// is malformed.
  static String? _formatPassiveEvent(
    String sentinel,
    String tag,
    String? myUserId, {
    required String verbPhrase,
  }) {
    final parts = _parseUuidUsername(sentinel, tag);
    if (parts == null) return null;
    final (uuid, username) = parts;
    final subject = _subjectFor(
      uuid,
      username,
      myUserId,
      selfPronoun: 'You were',
      peerSuffix: 'was',
    );
    return '$subject $verbPhrase';
  }

  /// Build the subject phrase for a system event. When [uuid] matches
  /// [myUserId] the [selfPronoun] is used verbatim; otherwise the
  /// [username] is rendered, optionally followed by [peerSuffix] (e.g.
  /// "alice was").
  static String _subjectFor(
    String uuid,
    String username,
    String? myUserId, {
    required String selfPronoun,
    String? peerSuffix,
  }) {
    final isMe = myUserId != null && uuid == myUserId;
    if (isMe) return selfPronoun;
    return peerSuffix == null ? username : '$username $peerSuffix';
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
      'thread_root_id': threadRootId,
      'reply_count': replyCount,
      'last_reply_snippet': latestReplyPreview,
      'last_reply_at': lastReplyAt?.toIso8601String(),
      'recent_replier_usernames': recentReplierUsernames,
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
    Object? threadRootId = _sentinel,
    int? replyCount,
    Object? latestReplyPreview = _sentinel,
    Object? lastReplyAt = _sentinel,
    List<String>? recentReplierUsernames,
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
      threadRootId: threadRootId == _sentinel
          ? this.threadRootId
          : threadRootId as String?,
      replyCount: replyCount ?? this.replyCount,
      latestReplyPreview: latestReplyPreview == _sentinel
          ? this.latestReplyPreview
          : latestReplyPreview as String?,
      lastReplyAt: lastReplyAt == _sentinel
          ? this.lastReplyAt
          : lastReplyAt as DateTime?,
      recentReplierUsernames:
          recentReplierUsernames ?? this.recentReplierUsernames,
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
            threadRootId == other.threadRootId &&
            replyCount == other.replyCount &&
            latestReplyPreview == other.latestReplyPreview &&
            lastReplyAt == other.lastReplyAt &&
            _listEquals(recentReplierUsernames, other.recentReplierUsernames) &&
            pinnedById == other.pinnedById &&
            pinnedAt == other.pinnedAt &&
            expiresAt == other.expiresAt &&
            failedContent == other.failedContent;
  }

  @override
  int get hashCode => Object.hashAll([
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
    threadRootId,
    replyCount,
    latestReplyPreview,
    lastReplyAt,
    Object.hashAll(recentReplierUsernames),
    pinnedById,
    pinnedAt,
    expiresAt,
    failedContent,
  ]);
}
