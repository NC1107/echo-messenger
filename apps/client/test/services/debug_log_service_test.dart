import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:echo_app/src/services/debug_log_service.dart';

// ---------------------------------------------------------------------------
// Fake path_provider so the service can resolve a temp directory in tests.
// ---------------------------------------------------------------------------

class _FakePathProvider
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String tempPath;
  _FakePathProvider(this.tempPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;

  // Required overrides -- unused in these tests.
  @override
  Future<String?> getTemporaryPath() async => tempPath;
  @override
  Future<String?> getApplicationSupportPath() async => tempPath;
  @override
  Future<String?> getLibraryPath() async => null;
  @override
  Future<String?> getApplicationCachePath() async => tempPath;
  @override
  Future<String?> getExternalStoragePath() async => null;
  @override
  Future<List<String>?> getExternalCachePaths() async => null;
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => null;
  @override
  Future<String?> getDownloadsPath() async => null;
}

void main() {
  late DebugLogService service;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('echo_debug_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDownAll(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    service = DebugLogService.instance;
    // Reset to a clean state and point at the temp directory for persistence
    // tests.  The override ensures the log file lands in the temp dir rather
    // than the real documents directory.
    service.resetForTest(overrideLogFilePath: '${tempDir.path}/echo-debug.log');
  });

  tearDown(() {
    // Clean up any log file left by the test.
    final file = File('${tempDir.path}/echo-debug.log');
    if (file.existsSync()) file.deleteSync();
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

    test('log accepts fatal level', () {
      service.log(LogLevel.fatal, 'platform', 'uncaught exception');
      expect(service.entries.first.level, LogLevel.fatal);
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

    test('maxEntries is 5000', () {
      expect(DebugLogService.maxEntries, 5000);
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

    test('redacts UUIDs in logged messages', () {
      service.log(
        LogLevel.info,
        'WebSocket',
        'Decryption failed for conv a1b2c3d4-e5f6-7890-abcd-ef1234567890 '
            'from user 12345678-abcd-ef01-2345-678901234567',
      );

      final msg = service.entries.first.message;
      // Full UUIDs should be replaced with first 8 chars + "..."
      expect(msg, isNot(contains('a1b2c3d4-e5f6-7890-abcd-ef1234567890')));
      expect(msg, isNot(contains('12345678-abcd-ef01-2345-678901234567')));
      expect(msg, contains('a1b2c3d4...'));
      expect(msg, contains('12345678...'));
    });

    test('does not redact non-UUID strings', () {
      service.log(LogLevel.info, 'Test', 'normal message with no IDs');
      expect(service.entries.first.message, 'normal message with no IDs');
    });

    test('redacts multiple UUIDs in a single message', () {
      service.log(
        LogLevel.warning,
        'Test',
        'users aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee '
            'and 11111111-2222-3333-4444-555555555555 are chatting',
      );

      final msg = service.entries.first.message;
      expect(msg, contains('aaaaaaaa...'));
      expect(msg, contains('11111111...'));
      expect(msg, isNot(contains('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')));
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

    // -------------------------------------------------------------------------
    // DebugLogEntry serialization
    // -------------------------------------------------------------------------

    group('DebugLogEntry serialization', () {
      test('roundtrips through toJsonLine / tryFromJsonLine', () {
        final original = DebugLogEntry(
          timestamp: DateTime.utc(2026, 5, 16, 12, 0, 0),
          level: LogLevel.warning,
          source: 'Test',
          message: 'hello world',
        );
        final line = original.toJsonLine();
        final restored = DebugLogEntry.tryFromJsonLine(line);
        expect(restored, isNotNull);
        expect(restored!.level, LogLevel.warning);
        expect(restored.source, 'Test');
        expect(restored.message, 'hello world');
        expect(restored.timestamp, original.timestamp);
      });

      test('tryFromJsonLine returns null for garbage input', () {
        expect(DebugLogEntry.tryFromJsonLine('not json'), isNull);
        expect(DebugLogEntry.tryFromJsonLine(''), isNull);
        expect(DebugLogEntry.tryFromJsonLine('{invalid}'), isNull);
      });

      test('tryFromJsonLine tolerates unknown level string', () {
        final entry = DebugLogEntry.tryFromJsonLine(
          '{"t":"2026-05-16T00:00:00.000Z","l":"bogus","s":"S","m":"M"}',
        );
        expect(entry, isNotNull);
        expect(entry!.level, LogLevel.info); // fallback
      });
    });

    // -------------------------------------------------------------------------
    // Persistence
    // -------------------------------------------------------------------------

    group('persistence', () {
      test(
        'flush writes entries to disk and loadAllEntries reads them back',
        () async {
          service.log(LogLevel.info, 'Persist', 'breadcrumb A');
          service.log(LogLevel.error, 'Persist', 'breadcrumb B');

          // Force an immediate flush (bypasses the debounce timer).
          await service.flush();

          // Verify the file was written.
          final file = File('${tempDir.path}/echo-debug.log');
          expect(file.existsSync(), isTrue);
          final content = file.readAsStringSync();
          expect(content, contains('breadcrumb A'));
          expect(content, contains('breadcrumb B'));

          // Simulate a "restart" by resetting the singleton's in-memory state
          // while keeping the same log file path.
          service.resetForTest(
            overrideLogFilePath: '${tempDir.path}/echo-debug.log',
          );
          expect(
            service.entries,
            isEmpty,
            reason: 'in-memory buffer cleared by resetForTest',
          );

          // loadAllEntries should reload from the file.
          final reloaded = await service.loadAllEntries();
          expect(reloaded.any((e) => e.message == 'breadcrumb A'), isTrue);
          expect(reloaded.any((e) => e.message == 'breadcrumb B'), isTrue);
        },
      );

      test('clear deletes the log file', () async {
        service.log(LogLevel.info, 'Persist', 'will be cleared');
        await service.flush();

        final file = File('${tempDir.path}/echo-debug.log');
        expect(file.existsSync(), isTrue);

        service.clear();
        // Give the async delete a moment to complete.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(file.existsSync(), isFalse);
      });

      test('loadAllEntries returns empty list when no file exists', () async {
        // File was deleted by tearDown / never created in this test path.
        final entries = await service.loadAllEntries();
        expect(entries, isEmpty);
      });

      test('corrupt lines in log file are silently skipped', () async {
        final file = File('${tempDir.path}/echo-debug.log');
        // Write one valid line and one corrupt line.
        final valid = DebugLogEntry(
          timestamp: DateTime.utc(2026, 1, 1),
          level: LogLevel.info,
          source: 'S',
          message: 'valid entry',
        );
        file.writeAsStringSync('${valid.toJsonLine()}\nnot-json-garbage\n');

        service.resetForTest(
          overrideLogFilePath: '${tempDir.path}/echo-debug.log',
        );
        final entries = await service.loadAllEntries();
        // Only the valid entry should be returned.
        expect(entries, hasLength(1));
        expect(entries.first.message, 'valid entry');
      });

      test(
        'forceFlush writes to disk immediately bypassing debounce',
        () async {
          service.log(LogLevel.info, 'Crash', 'pre-crash breadcrumb');

          // forceFlush must write without waiting for the debounce timer.
          await service.forceFlush();

          final file = File('${tempDir.path}/echo-debug.log');
          expect(file.existsSync(), isTrue);
          expect(file.readAsStringSync(), contains('pre-crash breadcrumb'));
        },
      );

      test('forceFlush cancels any pending debounce timer', () async {
        // Schedule a normal (debounced) write, then immediately force-flush.
        // The file should contain the entry without waiting for the timer.
        service.log(LogLevel.info, 'Flush', 'should be on disk now');
        await service.forceFlush();

        final file = File('${tempDir.path}/echo-debug.log');
        expect(file.existsSync(), isTrue);
        expect(file.readAsStringSync(), contains('should be on disk now'));
      });
    });

    group('urgent debounce', () {
      test('writeDebounceUrgent is shorter than writeDebounce', () {
        // Verifies the constants are set correctly: urgent path (warning+)
        // uses a much shorter window than the default info path.
        expect(
          DebugLogService.writeDebounceUrgent < DebugLogService.writeDebounce,
          isTrue,
        );
      });
    });
  });
}
