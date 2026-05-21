part of '../../notification_section.dart';

// ---------------------------------------------------------------------------
// Helpers (file-private)
// ---------------------------------------------------------------------------

TimeOfDay _parseTime(String value) {
  final parts = value.split(':');
  if (parts.length != 2) return const TimeOfDay(hour: 22, minute: 0);
  final hour = int.tryParse(parts[0]) ?? 22;
  final minute = int.tryParse(parts[1]) ?? 0;
  return TimeOfDay(hour: hour, minute: minute);
}

String _formatTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Returns true when [now] falls in the [start, end) window.
///
/// Handles overnight windows (e.g. 22:00 – 07:00 wraps past midnight).
bool _isWithinQuietHours(TimeOfDay now, TimeOfDay start, TimeOfDay end) {
  final nowMins = now.hour * 60 + now.minute;
  final startMins = start.hour * 60 + start.minute;
  final endMins = end.hour * 60 + end.minute;

  if (startMins <= endMins) {
    // Same-day window (e.g. 09:00 – 17:00).
    return nowMins >= startMins && nowMins < endMins;
  } else {
    // Overnight window (e.g. 22:00 – 07:00).
    return nowMins >= startMins || nowMins < endMins;
  }
}

// ---------------------------------------------------------------------------
// Public helpers used by notification handlers
// ---------------------------------------------------------------------------

/// Read notification preferences. Used by the message handler to decide
/// whether to show a notification.
Future<({bool enabled, bool dm, bool group})> loadNotificationPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  return (
    enabled: prefs.getBool(_kNotificationsEnabled) ?? true,
    dm: prefs.getBool(_kDmNotifications) ?? true,
    group: prefs.getBool(_kGroupNotifications) ?? true,
  );
}

/// Returns true when DND is active or the current time falls within quiet
/// hours. Notification service implementations call this to suppress
/// notifications without delivering them to the user.
Future<bool> shouldSuppressNotification() async {
  final prefs = await SharedPreferences.getInstance();

  final dnd = prefs.getBool(_kDndEnabled) ?? false;
  if (dnd) return true;

  final quietEnabled = prefs.getBool(_kQuietHoursEnabled) ?? false;
  if (!quietEnabled) return false;

  final start = _parseTime(
    prefs.getString(_kQuietHoursStart) ?? _kDefaultQuietStart,
  );
  final end = _parseTime(prefs.getString(_kQuietHoursEnd) ?? _kDefaultQuietEnd);
  return _isWithinQuietHours(TimeOfDay.now(), start, end);
}
