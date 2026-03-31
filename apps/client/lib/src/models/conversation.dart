class Conversation {
  final String id;
  final String? name;
  final bool isGroup;
  final String? lastMessage;
  final String? lastMessageTimestamp;
  final String? lastMessageSender;
  final int unreadCount;
  final List<ConversationMember> members;

  const Conversation({
    required this.id,
    this.name,
    required this.isGroup,
    this.lastMessage,
    this.lastMessageTimestamp,
    this.lastMessageSender,
    this.unreadCount = 0,
    this.members = const [],
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final membersList = (json['members'] as List?)
            ?.map((e) => ConversationMember.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return Conversation(
      id: json['conversation_id'] as String? ?? json['id'] as String,
      name: json['name'] as String?,
      isGroup: json['is_group'] as bool? ?? false,
      lastMessage: json['last_message'] as String?,
      lastMessageTimestamp: json['last_message_timestamp'] as String?,
      lastMessageSender: json['last_message_sender'] as String?,
      unreadCount: json['unread_count'] as int? ?? 0,
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
    bool? isGroup,
    String? lastMessage,
    String? lastMessageTimestamp,
    String? lastMessageSender,
    int? unreadCount,
    List<ConversationMember>? members,
  }) {
    return Conversation(
      id: id ?? this.id,
      name: name ?? this.name,
      isGroup: isGroup ?? this.isGroup,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTimestamp: lastMessageTimestamp ?? this.lastMessageTimestamp,
      lastMessageSender: lastMessageSender ?? this.lastMessageSender,
      unreadCount: unreadCount ?? this.unreadCount,
      members: members ?? this.members,
    );
  }
}

class ConversationMember {
  final String userId;
  final String username;

  const ConversationMember({
    required this.userId,
    required this.username,
  });

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      userId: json['user_id'] as String,
      username: json['username'] as String,
    );
  }
}
