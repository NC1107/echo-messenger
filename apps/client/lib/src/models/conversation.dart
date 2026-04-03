class Conversation {
  final String id;
  final String? name;
  final String? description;
  final bool isGroup;
  final bool isEncrypted;
  final String? lastMessage;
  final String? lastMessageTimestamp;
  final String? lastMessageSender;
  final int unreadCount;
  final bool isMuted;
  final List<ConversationMember> members;

  const Conversation({
    required this.id,
    this.name,
    this.description,
    required this.isGroup,
    this.isEncrypted = false,
    this.lastMessage,
    this.lastMessageTimestamp,
    this.lastMessageSender,
    this.unreadCount = 0,
    this.isMuted = false,
    this.members = const [],
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    var membersList =
        (json['members'] as List?)
            ?.map((e) => ConversationMember.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    // Fallback: if server returns peer_user_id/peer_username (old format)
    if (membersList.isEmpty && json['peer_user_id'] != null) {
      membersList = [
        ConversationMember(
          userId: json['peer_user_id'] as String,
          username: json['peer_username'] as String? ?? 'Unknown',
        ),
      ];
    }

    // Server returns kind as "direct"/"group", or is_group as bool
    final kind = json['kind'] as String?;
    final isGroupValue = json['is_group'] as bool? ?? (kind == 'group');

    // Server returns last_message as an object with content/sender_username/created_at
    String? lastMsg;
    String? lastMsgTimestamp;
    String? lastMsgSender;
    final lastMessageObj = json['last_message'];
    if (lastMessageObj is Map<String, dynamic>) {
      lastMsg = lastMessageObj['content'] as String?;
      lastMsgTimestamp = lastMessageObj['created_at'] as String?;
      lastMsgSender = lastMessageObj['sender_username'] as String?;
    } else if (lastMessageObj is String) {
      lastMsg = lastMessageObj;
      lastMsgTimestamp = json['last_message_timestamp'] as String?;
      lastMsgSender = json['last_message_sender'] as String?;
    }

    return Conversation(
      id: json['conversation_id'] as String? ?? json['id'] as String,
      name: (json['title'] ?? json['name']) as String?,
      description: json['description'] as String?,
      isGroup: isGroupValue,
      isEncrypted: json['is_encrypted'] as bool? ?? false,
      lastMessage: lastMsg,
      lastMessageTimestamp: lastMsgTimestamp,
      lastMessageSender: lastMsgSender,
      unreadCount: json['unread_count'] as int? ?? 0,
      isMuted: json['is_muted'] as bool? ?? false,
      members: membersList,
    );
  }

  /// Display name for the conversation: group name, peer username, or fallback.
  String displayName(String myUserId) {
    if (isGroup && name != null && name!.isNotEmpty) return name!;
    // For 1:1 chats, show the other person's name
    final peer = members.where((m) => m.userId != myUserId).firstOrNull;
    return peer?.username ?? name ?? 'Unknown';
  }

  Conversation copyWith({
    String? id,
    String? name,
    String? description,
    bool? isGroup,
    bool? isEncrypted,
    String? lastMessage,
    String? lastMessageTimestamp,
    String? lastMessageSender,
    int? unreadCount,
    bool? isMuted,
    List<ConversationMember>? members,
  }) {
    return Conversation(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      isGroup: isGroup ?? this.isGroup,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTimestamp: lastMessageTimestamp ?? this.lastMessageTimestamp,
      lastMessageSender: lastMessageSender ?? this.lastMessageSender,
      unreadCount: unreadCount ?? this.unreadCount,
      isMuted: isMuted ?? this.isMuted,
      members: members ?? this.members,
    );
  }
}

class ConversationMember {
  final String userId;
  final String username;
  final String? role;
  final String? avatarUrl;

  const ConversationMember({
    required this.userId,
    required this.username,
    this.role,
    this.avatarUrl,
  });

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      role: json['role'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}
