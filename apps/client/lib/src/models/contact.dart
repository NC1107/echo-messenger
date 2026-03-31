class Contact {
  final String id;
  final String userId;
  final String username;
  final String? displayName;
  final String status;

  const Contact({
    required this.id,
    required this.userId,
    required this.username,
    this.displayName,
    required this.status,
  });

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String?,
      status: json['status'] as String,
    );
  }
}
