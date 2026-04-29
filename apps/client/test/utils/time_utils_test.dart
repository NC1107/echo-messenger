import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/utils/time_utils.dart';

void main() {
  group('formatConversationTimestamp', () {
    test('returns empty string for null input', () {
      expect(formatConversationTimestamp(null), '');
    });

    test('returns empty string for empty string input', () {
      expect(formatConversationTimestamp(''), '');
    });

    test('returns empty string for invalid timestamp', () {
      expect(formatConversationTimestamp('not-a-date'), '');
    });

    test('returns HH:MM for a timestamp from today', () {
      // Build a timestamp that is today at 09:05 local time
      final now = DateTime.now();
      final todayAt9 = DateTime(now.year, now.month, now.day, 9, 5);
      final iso = todayAt9.toUtc().toIso8601String();

      final result = formatConversationTimestamp(iso);

      expect(result, matches(RegExp(r'^\d{2}:\d{2}$')));
    });

    test('returns Yesterday for a timestamp from yesterday', () {
      // Use 30h ago to ensure diff.inDays == 1 regardless of time of day.
      final iso = DateTime.now()
          .subtract(const Duration(hours: 30))
          .toUtc()
          .toIso8601String();

      expect(formatConversationTimestamp(iso), 'Yesterday');
    });

    test('returns abbreviated weekday for timestamps 2-6 days ago', () {
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));
      final iso = DateTime(
        threeDaysAgo.year,
        threeDaysAgo.month,
        threeDaysAgo.day,
        8,
        0,
      ).toUtc().toIso8601String();

      final result = formatConversationTimestamp(iso);
      expect(weekdays, contains(result));
    });

    test(
      'returns "Mmm d" for timestamps older than 7 days in the same year',
      () {
        final old = DateTime.now().subtract(const Duration(days: 10));
        final iso = DateTime(
          old.year,
          old.month,
          old.day,
          8,
          0,
        ).toUtc().toIso8601String();

        final result = formatConversationTimestamp(iso);
        // Should match pattern like "Apr 17" or "Dec 3" -- unambiguous month
        // abbreviation followed by the day of month.
        expect(result, matches(RegExp(r'^[A-Z][a-z]{2} \d{1,2}$')));
      },
    );

    test('appends year for timestamps from a previous calendar year', () {
      final last = DateTime.now().subtract(const Duration(days: 400));
      final iso = DateTime(
        last.year,
        last.month,
        last.day,
        8,
        0,
      ).toUtc().toIso8601String();

      final result = formatConversationTimestamp(iso);
      // Pattern: "Apr 17, 2024"
      expect(result, matches(RegExp(r'^[A-Z][a-z]{2} \d{1,2}, \d{4}$')));
    });
  });

  group('formatMessageTimestamp', () {
    test('returns empty string for invalid timestamp', () {
      expect(formatMessageTimestamp('not-a-date'), '');
    });

    test('formats midnight as 12:00 AM', () {
      final midnight = DateTime(2026, 3, 15, 0, 0).toUtc().toIso8601String();
      // Convert UTC to local to build expected value
      final dt = DateTime.parse(midnight).toLocal();
      final result = formatMessageTimestamp(midnight);
      if (dt.hour == 0) {
        expect(result, startsWith('12:'));
        expect(result, endsWith('AM'));
      }
    });

    test('formats noon as 12:xx PM', () {
      final noon = DateTime(2026, 3, 15, 12, 0).toUtc().toIso8601String();
      final dt = DateTime.parse(noon).toLocal();
      final result = formatMessageTimestamp(noon);
      if (dt.hour == 12) {
        expect(result, startsWith('12:'));
        expect(result, endsWith('PM'));
      }
    });

    test('formats afternoon hour correctly', () {
      // Use a timestamp from yesterday to guarantee absolute format
      final ts = DateTime.now()
          .subtract(const Duration(hours: 20))
          .toUtc()
          .toIso8601String();
      final result = formatMessageTimestamp(ts);
      expect(result, matches(RegExp(r'^\d{1,2}:\d{2} (AM|PM)$')));
    });

    test('formats morning hour correctly', () {
      final ts = DateTime.now()
          .subtract(const Duration(hours: 14))
          .toUtc()
          .toIso8601String();
      final result = formatMessageTimestamp(ts);
      expect(result, matches(RegExp(r'^\d{1,2}:\d{2} (AM|PM)$')));
    });

    test('pads minutes with leading zero', () {
      // 10:05 UTC
      final ts = DateTime.utc(2026, 1, 1, 10, 5).toIso8601String();
      final result = formatMessageTimestamp(ts);
      // minutes portion should be "05"
      final parts = result.split(':');
      expect(parts.length, 2);
      final minutePart = parts[1].split(' ')[0];
      expect(minutePart.length, 2);
    });

    test('returns "just now" for timestamps less than 60 seconds ago', () {
      final ts = DateTime.now()
          .subtract(const Duration(seconds: 30))
          .toUtc()
          .toIso8601String();
      expect(formatMessageTimestamp(ts), 'just now');
    });

    test(
      'returns relative minutes for timestamps less than 60 minutes ago',
      () {
        final ts = DateTime.now()
            .subtract(const Duration(minutes: 5))
            .toUtc()
            .toIso8601String();
        expect(formatMessageTimestamp(ts), '5m ago');
      },
    );

    test('returns absolute format for timestamps more than 60 minutes ago', () {
      final ts = DateTime.now()
          .subtract(const Duration(hours: 2))
          .toUtc()
          .toIso8601String();
      final result = formatMessageTimestamp(ts);
      expect(result, matches(RegExp(r'^\d{1,2}:\d{2} (AM|PM)$')));
    });
  });

  group('formatPeerStatusLabel (#503)', () {
    test('online returns "online" regardless of lastSeen', () {
      expect(formatPeerStatusLabel(isOnline: true, lastSeen: null), 'online');
      expect(
        formatPeerStatusLabel(isOnline: true, lastSeen: DateTime.now()),
        'online',
      );
    });

    test('offline with no lastSeen returns "offline"', () {
      expect(formatPeerStatusLabel(isOnline: false, lastSeen: null), 'offline');
    });

    test('offline with recent lastSeen renders "last seen just now"', () {
      final ts = DateTime.now().subtract(const Duration(seconds: 30)).toUtc();
      expect(
        formatPeerStatusLabel(isOnline: false, lastSeen: ts),
        'last seen just now',
      );
    });

    test('offline with minutes-ago lastSeen renders "last seen Nm ago"', () {
      final ts = DateTime.now().subtract(const Duration(minutes: 5)).toUtc();
      expect(
        formatPeerStatusLabel(isOnline: false, lastSeen: ts),
        'last seen 5m ago',
      );
    });

    test('offline with hours-ago lastSeen falls back to absolute time', () {
      final ts = DateTime.now().subtract(const Duration(hours: 3)).toUtc();
      expect(
        formatPeerStatusLabel(isOnline: false, lastSeen: ts),
        matches(RegExp(r'^last seen \d{1,2}:\d{2} (AM|PM)$')),
      );
    });
  });
}
