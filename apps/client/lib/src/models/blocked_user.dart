class BlockedUser {
  final String blockedId;
  final String username;
  final String? displayName;

  const BlockedUser({
    required this.blockedId,
    required this.username,
    this.displayName,
  });

  factory BlockedUser.fromJson(Map<String, dynamic> json) {
    return BlockedUser(
      blockedId: json['blocked_id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String?,
    );
  }
}
