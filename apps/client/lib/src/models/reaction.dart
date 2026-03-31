class Reaction {
  final String messageId;
  final String userId;
  final String username;
  final String emoji;

  const Reaction({
    required this.messageId,
    required this.userId,
    required this.username,
    required this.emoji,
  });

  factory Reaction.fromJson(Map<String, dynamic> json) {
    return Reaction(
      messageId: json['message_id'] as String,
      userId: json['user_id'] as String,
      username: json['username'] as String,
      emoji: json['emoji'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'message_id': messageId,
    'user_id': userId,
    'username': username,
    'emoji': emoji,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Reaction &&
          messageId == other.messageId &&
          userId == other.userId &&
          emoji == other.emoji;

  @override
  int get hashCode => Object.hash(messageId, userId, emoji);
}
