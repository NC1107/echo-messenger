/// Format a timestamp string for display in the conversation list sidebar.
///
/// Shows "HH:MM" for today, "Yesterday" for yesterday, abbreviated weekday
/// for the last 6 days, and an unambiguous "MMM d" (e.g. "Apr 17") for
/// anything older. The previous "d/m/yyyy" format was ambiguous between US
/// (M/D) and EU (D/M) readers; "Apr 17" is unambiguous in English without
/// pulling in a locale dependency.
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
      return _formatOlderDate(dt);
    }

    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  } catch (_) {
    return '';
  }
}

const _shortMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatOlderDate(DateTime d) {
  // "Apr 17" within the same calendar year, "Apr 17, 2024" otherwise.
  final monthDay = '${_shortMonths[d.month - 1]} ${d.day}';
  final now = DateTime.now();
  if (d.year == now.year) return monthDay;
  return '$monthDay, ${d.year}';
}

/// Format a timestamp string for display on individual messages.
///
/// Shows relative time for recent messages ("just now", "5m ago") and
/// falls back to 12-hour format with AM/PM for older messages.
String formatMessageTimestamp(String timestamp) {
  try {
    final dt = DateTime.parse(timestamp).toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (!diff.isNegative && diff.inSeconds < 60) return 'just now';
    if (!diff.isNegative && diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    }

    final hour = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = hour >= 12 ? 'PM' : 'AM';
    final int displayHour;
    if (hour == 0) {
      displayHour = 12;
    } else if (hour > 12) {
      displayHour = hour - 12;
    } else {
      displayHour = hour;
    }
    return '$displayHour:$minute $ampm';
  } catch (_) {
    return '';
  }
}
