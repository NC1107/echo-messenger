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
      return formatShortDate(dt);
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

/// "Apr 17" within the current calendar year, "Apr 17, 2024" otherwise.
/// Unambiguous across US/EU readers without a locale dependency.
String formatShortDate(DateTime d) {
  final monthDay = '${_shortMonths[d.month - 1]} ${d.day}';
  final now = DateTime.now();
  if (d.year == now.year) return monthDay;
  return '$monthDay, ${d.year}';
}

/// Compact "time ago": "just now" (<1m), "5m ago", "3h ago", "2d ago" (<7d).
/// After a week it calls [older] with the timestamp when supplied (e.g. a short
/// date), otherwise falls back to "Nw ago". A future timestamp reads as "just
/// now" rather than leaking a negative duration.
///
/// This is the single source of truth for compact relative labels in lists,
/// chips, and search results — callers used to hand-roll five slightly
/// different ladders (mismatched thresholds, some UTC some local).
String formatRelativeTimeShort(
  DateTime when, {
  String Function(DateTime)? older,
}) {
  final diff = DateTime.now().difference(when);
  if (diff.isNegative || diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (older != null) return older(when);
  return '${(diff.inDays / 7).floor()}w ago';
}

/// Verbose, pluralized "time ago": "just now" (<1m), "5 minutes ago",
/// "2 hours ago", "3 days ago" (<30d), "2 months ago" (<1y), then years.
/// Used on detail surfaces (safety number, device list) where the long form
/// reads better than the compact chips above.
String formatRelativeTimeLong(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.isNegative || diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return _pluralAgo(diff.inMinutes, 'minute');
  if (diff.inHours < 24) return _pluralAgo(diff.inHours, 'hour');
  if (diff.inDays < 30) return _pluralAgo(diff.inDays, 'day');
  if (diff.inDays < 365) return _pluralAgo(diff.inDays ~/ 30, 'month');
  return _pluralAgo(diff.inDays ~/ 365, 'year');
}

String _pluralAgo(int n, String unit) => '$n ${n == 1 ? unit : '${unit}s'} ago';

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

/// Build the chat-header status line for a 1:1 peer (#503).
///
/// - `online` → returns `'online'`.
/// - `offline` with a known [lastSeen] timestamp → returns
///   `'last seen <relative>'` where relative is from [formatMessageTimestamp].
/// - `offline` with no [lastSeen] → returns `'offline'`.
String formatPeerStatusLabel({
  required bool isOnline,
  required DateTime? lastSeen,
}) {
  if (isOnline) return 'online';
  if (lastSeen != null) {
    return 'last seen ${formatMessageTimestamp(lastSeen.toIso8601String())}';
  }
  return 'offline';
}
