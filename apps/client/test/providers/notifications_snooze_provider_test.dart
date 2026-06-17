import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/notifications_snooze_provider.dart';

void main() {
  group('resolveSnoozeUntil', () {
    test('1 hour preset lands an hour in the future', () {
      final now = DateTime.utc(2026, 5, 28, 12, 0);
      final until = resolveSnoozeUntil(SnoozeDuration.oneHour, now: now);
      expect(until.isUtc, isTrue);
      expect(until.difference(now), const Duration(hours: 1));
    });

    test('8 hour preset lands 8 hours in the future', () {
      final now = DateTime.utc(2026, 5, 28, 12, 0);
      final until = resolveSnoozeUntil(SnoozeDuration.eightHours, now: now);
      expect(until.difference(now), const Duration(hours: 8));
    });

    test('24 hour preset lands 24 hours in the future', () {
      final now = DateTime.utc(2026, 5, 28, 12, 0);
      final until = resolveSnoozeUntil(
        SnoozeDuration.twentyFourHours,
        now: now,
      );
      expect(until.difference(now), const Duration(hours: 24));
    });

    test('tomorrowMorning lands on the next day at 9 AM local', () {
      // Local 2026-05-28 22:30 → tomorrow morning is 2026-05-29 09:00 local.
      final now = DateTime(2026, 5, 28, 22, 30);
      final until = resolveSnoozeUntil(
        SnoozeDuration.tomorrowMorning,
        now: now,
      );
      // Convert back to local for the day/hour assertion regardless of TZ.
      final local = until.toLocal();
      expect(local.year, 2026);
      expect(local.month, 5);
      expect(local.day, 29);
      expect(local.hour, 9);
      expect(local.minute, 0);
    });

    test('tomorrowMorning still rolls forward when called just after 9 AM', () {
      // Local 09:05 today → tomorrow morning is still the next calendar day.
      final now = DateTime(2026, 5, 28, 9, 5);
      final until = resolveSnoozeUntil(
        SnoozeDuration.tomorrowMorning,
        now: now,
      );
      final local = until.toLocal();
      expect(local.day, 29);
      expect(local.hour, 9);
    });

    test('all presets return UTC instants', () {
      for (final preset in SnoozeDuration.values) {
        final until = resolveSnoozeUntil(preset);
        expect(until.isUtc, isTrue, reason: '$preset must be UTC');
      }
    });
  });
}
