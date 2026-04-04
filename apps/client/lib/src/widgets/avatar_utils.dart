import 'package:flutter/material.dart';

/// Shared avatar builder used across conversation panel widgets.
Widget buildAvatar({
  String? imageUrl,
  required String name,
  required double radius,
  Color? bgColor,
  Widget? fallbackIcon,
}) {
  if (imageUrl != null && imageUrl.isNotEmpty) {
    return CircleAvatar(
      radius: radius,
      backgroundImage: NetworkImage(imageUrl),
    );
  }
  return CircleAvatar(
    radius: radius,
    backgroundColor: bgColor ?? avatarColor(name),
    child:
        fallbackIcon ??
        Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.8,
            fontWeight: FontWeight.w600,
          ),
        ),
  );
}

/// Deterministic color from a name string.
Color avatarColor(String name) {
  const colors = [
    Color(0xFFE06666),
    Color(0xFFF6B05C),
    Color(0xFF57D28F),
    Color(0xFF5DADE2),
    Color(0xFFAF7AC5),
    Color(0xFFEB984E),
  ];
  final index = name.hashCode.abs() % colors.length;
  return colors[index];
}

/// Wider palette for group avatars, derived from group name hash.
const _groupColors = [
  Color(0xFF22C55E), // green
  Color(0xFFEF4444), // red
  Color(0xFF3B82F6), // blue
  Color(0xFFF59E0B), // amber
  Color(0xFF8B5CF6), // violet
  Color(0xFFEC4899), // pink
  Color(0xFF14B8A6), // teal
  Color(0xFFF97316), // orange
  Color(0xFF6366F1), // indigo
  Color(0xFF06B6D4), // cyan
];

/// Deterministic color for group avatars.
Color groupAvatarColor(String name) {
  return _groupColors[name.hashCode.abs() % _groupColors.length];
}
