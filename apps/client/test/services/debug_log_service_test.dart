import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/debug_log_service.dart';

void main() {
  late DebugLogService service;

  setUp(() {
    service = DebugLogService.instance;
    service.clear();
  });

  group('DebugLogService', () {
    test('starts empty', () {
      expect(service.entries, isEmpty);
    });

    test('log adds an entry', () {
      service.log(LogLevel.info, 'Test', 'Hello');

      expect(service.entries, hasLength(1));
      expect(service.entries.first.level, LogLevel.info);
      expect(service.entries.first.source, 'Test');
      expect(service.entries.first.message, 'Hello');
    });

    test('log preserves insertion order', () {
      service.log(LogLevel.info, 'A', 'first');
      service.log(LogLevel.warning, 'B', 'second');
      service.log(LogLevel.error, 'C', 'third');

      expect(service.entries, hasLength(3));
      expect(service.entries[0].message, 'first');
      expect(service.entries[1].message, 'second');
      expect(service.entries[2].message, 'third');
    });

    test('log evicts oldest when exceeding maxEntries', () {
      for (var i = 0; i < DebugLogService.maxEntries + 10; i++) {
        service.log(LogLevel.info, 'Src', 'msg $i');
      }

      expect(service.entries, hasLength(DebugLogService.maxEntries));
      // Oldest entries should be evicted; newest should remain.
      expect(service.entries.first.message, 'msg 10');
      expect(
        service.entries.last.message,
        'msg ${DebugLogService.maxEntries + 9}',
      );
    });

    test('clear removes all entries', () {
      service.log(LogLevel.info, 'Test', 'one');
      service.log(LogLevel.info, 'Test', 'two');
      service.clear();

      expect(service.entries, isEmpty);
    });

    test('entries returns an unmodifiable list', () {
      service.log(LogLevel.info, 'Test', 'value');

      expect(
        () => service.entries.add(
          DebugLogEntry(
            timestamp: DateTime.now(),
            level: LogLevel.info,
            source: 'Hack',
            message: 'injected',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('notifies listeners on log', () {
      var notified = false;
      service.addListener(() => notified = true);

      service.log(LogLevel.info, 'Test', 'ping');
      expect(notified, isTrue);
    });

    test('notifies listeners on clear', () {
      service.log(LogLevel.info, 'Test', 'data');
      var notified = false;
      service.addListener(() => notified = true);

      service.clear();
      expect(notified, isTrue);
    });

    test('DebugLogEntry fields are set correctly', () {
      final before = DateTime.now();
      service.log(LogLevel.error, 'Crypto', 'key failure');
      final after = DateTime.now();

      final entry = service.entries.first;
      expect(entry.level, LogLevel.error);
      expect(entry.source, 'Crypto');
      expect(entry.message, 'key failure');
      expect(
        entry.timestamp.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        entry.timestamp.isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
  });
}
