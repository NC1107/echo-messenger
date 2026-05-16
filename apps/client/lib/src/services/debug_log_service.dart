import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, IOException;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Severity level for debug log entries.
enum LogLevel { info, warning, error, fatal }

/// A single timestamped log entry captured by [DebugLogService].
class DebugLogEntry {
  final DateTime timestamp;
  final LogLevel level;

  /// Subsystem that produced the log, e.g. "VoiceRTC", "WebSocket", "Crypto".
  final String source;
  final String message;

  const DebugLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  /// Serialize to a single JSON line for file storage.
  String toJsonLine() {
    return jsonEncode({
      't': timestamp.toIso8601String(),
      'l': level.name,
      's': source,
      'm': message,
    });
  }

  /// Deserialize from a JSON line produced by [toJsonLine].
  ///
  /// Returns null on any parse failure so a single corrupt line never
  /// prevents loading the rest of the log file.
  static DebugLogEntry? tryFromJsonLine(String line) {
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      final levelStr = map['l'] as String? ?? 'info';
      final level = LogLevel.values.firstWhere(
        (v) => v.name == levelStr,
        orElse: () => LogLevel.info,
      );
      return DebugLogEntry(
        timestamp: DateTime.parse(map['t'] as String),
        level: level,
        source: map['s'] as String? ?? '',
        message: map['m'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Singleton service that captures debug log entries in a bounded ring buffer
/// and persists them to `<documents>/echo-debug.log`.
///
/// Persistence makes crashes debuggable on platforms without console access
/// (iOS TestFlight, Android release builds). The file is a newline-delimited
/// JSON stream capped at [maxEntries] lines; older lines are evicted when the
/// buffer is full.
///
/// Mixes in [ChangeNotifier] so Settings UI widgets can listen for new entries
/// and rebuild automatically.
class DebugLogService with ChangeNotifier {
  DebugLogService._();

  static final instance = DebugLogService._();

  final _entries = <DebugLogEntry>[];

  /// Maximum number of entries retained in memory and persisted to disk.
  static const maxEntries = 5000;

  /// File write is debounced by this duration to coalesce rapid log bursts
  /// (e.g., 50 voice-join breadcrumbs) into a single I/O operation.
  static const _writeDebounce = Duration(milliseconds: 500);

  Timer? _writeTimer;

  /// Lazily resolved log file path. Null on web or while not yet resolved.
  String? _logFilePath;

  /// Whether the initial file load has completed.
  bool _loaded = false;

  /// Matches standard UUIDs (8-4-4-4-12 hex).
  static final _uuidRegex = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );

  /// Unmodifiable snapshot of the current in-memory entries (oldest first).
  List<DebugLogEntry> get entries => List.unmodifiable(_entries);

  /// Truncate UUIDs to their first 8 hex characters to avoid leaking full
  /// user/conversation IDs into the log buffer.
  String _redact(String msg) =>
      msg.replaceAllMapped(_uuidRegex, (m) => '${m[0]!.substring(0, 8)}...');

  /// Resolve and cache the path to the log file.
  ///
  /// Returns null on web (no filesystem) or when `path_provider` fails.
  Future<String?> _resolveLogFilePath() async {
    if (kIsWeb) return null;
    if (_logFilePath != null) return _logFilePath;
    try {
      // getApplicationDocumentsDirectory works on iOS, Android, macOS,
      // Linux, and Windows. On Linux this is ~/Documents/<app> which is
      // less ideal than Support, but it's readable without a special
      // entitlement on iOS — which is the primary target for this feature.
      final dir = await getApplicationDocumentsDirectory();
      _logFilePath = '${dir.path}/echo-debug.log';
      return _logFilePath;
    } catch (_) {
      return null;
    }
  }

  /// Load persisted entries from disk into the in-memory buffer.
  ///
  /// Called once during service initialization.  Safe to call multiple times
  /// — subsequent calls are no-ops.
  Future<void> _loadFromFile() async {
    if (_loaded) return;
    _loaded = true;

    final path = await _resolveLogFilePath();
    if (path == null) return;

    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final lines = await file.readAsLines();
      final loaded = <DebugLogEntry>[];
      for (final line in lines) {
        if (line.isEmpty) continue;
        final entry = DebugLogEntry.tryFromJsonLine(line);
        if (entry != null) loaded.add(entry);
      }
      // Apply cap: keep only the most recent maxEntries from the file.
      final start = loaded.length > maxEntries ? loaded.length - maxEntries : 0;
      _entries.addAll(loaded.sublist(start));
    } on IOException catch (_) {
      // Unreadable file (permissions, corruption) — start fresh.
    }
  }

  /// Write the current in-memory buffer to disk, replacing the file.
  ///
  /// Uses a debounce so rapid bursts of log calls only cause one I/O round
  /// trip.  No-op on web.
  void _scheduleWrite() {
    if (kIsWeb) return;
    _writeTimer?.cancel();
    _writeTimer = Timer(_writeDebounce, _flushToDisk);
  }

  Future<void> _flushToDisk() async {
    final path = await _resolveLogFilePath();
    if (path == null) return;
    try {
      // Snapshot the current buffer under a local variable so a concurrent
      // `log()` call cannot mutate _entries while we're serializing.
      final snapshot = List<DebugLogEntry>.from(_entries);
      final lines = snapshot.map((e) => e.toJsonLine()).join('\n');
      await File(path).writeAsString('$lines\n');
    } on IOException catch (_) {
      // Swallow write errors silently — logging a log-write failure would
      // cause infinite recursion and the in-memory buffer stays intact.
    }
  }

  /// Append a new log entry, evicting the oldest if the buffer is full.
  ///
  /// Initialization (first-call file load) is triggered lazily on the first
  /// [log] call.  Any entries logged before the file load completes are
  /// buffered in memory and included in the first flush.
  ///
  /// UUIDs in [message] are automatically truncated to prevent leaking full
  /// identifiers into the log.
  void log(LogLevel level, String source, String message) {
    // Kick off a one-time file load so that any entries already on disk
    // appear in the in-memory buffer before we start evicting.  This is
    // async and may complete after several log() calls have already been
    // added — that is fine; duplicates are not a concern because we only
    // load once and subsequent log() calls append to the already-loaded
    // buffer.
    if (!_loaded && !kIsWeb) {
      _loadFromFile();
    }

    _entries.add(
      DebugLogEntry(
        timestamp: DateTime.now(),
        level: level,
        source: source,
        message: _redact(message),
      ),
    );
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    _scheduleWrite();
    notifyListeners();
  }

  /// Read all persisted entries from the log file.
  ///
  /// Triggers the initial file load if it hasn't happened yet, then returns
  /// the current in-memory buffer.  On web, returns an empty list.
  Future<List<DebugLogEntry>> loadAllEntries() async {
    await _loadFromFile();
    return List.unmodifiable(_entries);
  }

  /// Remove all stored entries from memory and delete the log file.
  void clear() {
    _entries.clear();
    _writeTimer?.cancel();
    _writeTimer = null;
    // Delete the log file asynchronously.  Failures are silently ignored.
    if (!kIsWeb) {
      _resolveLogFilePath().then((path) {
        if (path == null) return;
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
      }).ignore();
    }
    notifyListeners();
  }

  /// Force an immediate flush of the in-memory buffer to disk, bypassing the
  /// debounce timer.  Intended for use just before process exit.
  Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    await _flushToDisk();
  }

  // ---------------------------------------------------------------------------
  // Test helpers
  // ---------------------------------------------------------------------------

  /// Reset internal state for tests that need a fresh service.
  ///
  /// Cancels pending timers, clears entries, and resets the loaded flag so
  /// the next [log] or [loadAllEntries] call triggers a fresh file load.
  @visibleForTesting
  void resetForTest({String? overrideLogFilePath}) {
    _writeTimer?.cancel();
    _writeTimer = null;
    _entries.clear();
    _loaded = false;
    _logFilePath = overrideLogFilePath;
  }
}
