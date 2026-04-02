class GroupChannel {
  final String id;
  final String conversationId;
  final String name;
  final String kind;
  final String? topic;
  final int position;
  final String createdAt;

  const GroupChannel({
    required this.id,
    required this.conversationId,
    required this.name,
    required this.kind,
    this.topic,
    required this.position,
    required this.createdAt,
  });

  bool get isText => kind == 'text';
  bool get isVoice => kind == 'voice';

  factory GroupChannel.fromJson(Map<String, dynamic> json) {
    return GroupChannel(
      id: (json['id'] ?? '').toString(),
      conversationId: (json['conversation_id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      kind: (json['kind'] ?? 'text').toString(),
      topic: json['topic'] as String?,
      position: (json['position'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}

class VoiceSessionMember {
  final String channelId;
  final String userId;
  final String username;
  final String? avatarUrl;
  final bool isMuted;
  final bool isDeafened;
  final bool pushToTalk;
  final String joinedAt;
  final String updatedAt;

  const VoiceSessionMember({
    required this.channelId,
    required this.userId,
    required this.username,
    this.avatarUrl,
    required this.isMuted,
    required this.isDeafened,
    required this.pushToTalk,
    required this.joinedAt,
    required this.updatedAt,
  });

  factory VoiceSessionMember.fromJson(Map<String, dynamic> json) {
    return VoiceSessionMember(
      channelId: (json['channel_id'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      username: (json['username'] ?? '').toString(),
      avatarUrl: json['avatar_url'] as String?,
      isMuted: json['is_muted'] as bool? ?? false,
      isDeafened: json['is_deafened'] as bool? ?? false,
      pushToTalk: json['push_to_talk'] as bool? ?? false,
      joinedAt: (json['joined_at'] ?? '').toString(),
      updatedAt: (json['updated_at'] ?? '').toString(),
    );
  }
}
