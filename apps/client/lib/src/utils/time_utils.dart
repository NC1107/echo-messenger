/// Format a timestamp string for display in the conversation list sidebar.
///
/// Shows "HH:MM" for today, "Yesterday" for yesterday, abbreviated weekday
/// for the last 7 days, and "d/m/yyyy" for older dates.
String formatConversationTimestamp(String? timestamp) {
  if (timestamp == null || timestamp.isEmpty) return '';
  try {
    final dt = DateTime.parse(timestamp).toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inDays > 0) {
      if (diff.inDays == 1) return 'Yesterday';
      if (diff.inDays < 7) {
        const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return days[dt.weekday - 1];
      }
      return '${dt.day}/${dt.month}/${dt.year}';
    }

    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  } catch (_) {
    return '';
  }
}

/// Format a timestamp string for display on individual messages.
///
/// Shows time in 12-hour format with AM/PM (e.g. "2:05 PM").
String formatMessageTimestamp(String timestamp) {
  try {
    final dt = DateTime.parse(timestamp).toLocal();
    final hour = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:$minute $ampm';
  } catch (_) {
    return '';
  }
}
