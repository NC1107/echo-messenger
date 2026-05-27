import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, IOException;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../version.dart' show appVersion;

/// Severity level for debug log entries.
///
/// Ordered low-to-high: `fine` is the most verbose (trace-style breadcrumbs
/// that are useful when debugging but shouldn't dominate production logs);
/// `fatal` is reserved for unrecoverable errors that immediately precede a
/// crash. Production-noise breadcrumbs (lifecycle transitions, routine
/// crypto init, swallowed benign errors) should log at `fine` so they stay
/// in the on-disk ring buffer for triage without spamming the in-app viewer.
enum LogLevel { fine, info, warning, error, fatal }

/// A single timestamped log entry captured by [DebugLogService].
class DebugLogEntry {
  final DateTime timestamp;
  final LogLevel level;

  /// Subsystem that produced the log, e.g. "VoiceRTC", "WebSocket", "Crypto".
  final String source;
  final String message;

  /// App version that produced the entry. Persisted alongside the entry
  /// so a log exported from one build is still readable when the user
  /// has since upgraded. Stamped from [appVersion] by default.
  final String version;

  DebugLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    String? version,
  }) : version = version ?? appVersion;

  /// Serialize to a single JSON line for file storage.
  String toJsonLine() {
    return jsonEncode({
      't': timestamp.toIso8601String(),
      'l': level.name,
      's': source,
      'm': message,
      'v': version,
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
        version: map['v'] as String?,
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
  static const writeDebounce = Duration(milliseconds: 500);

  /// Shorter debounce applied when the log level is [LogLevel.warning] or
  /// above so elevated-severity breadcrumbs reach disk faster and survive
  /// a crash that occurs shortly after logging.
  static const writeDebounceUrgent = Duration(milliseconds: 50);

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
      // Documents dir is readable on iOS without extra entitlement (primary target).
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
  /// trip.  No-op on web.  [urgent] uses [_writeDebounceUrgent] (50 ms)
  /// instead of the normal 500 ms window.
  void _scheduleWrite({bool urgent = false}) {
    if (kIsWeb) return;
    _writeTimer?.cancel();
    final delay = urgent ? writeDebounceUrgent : writeDebounce;
    _writeTimer = Timer(delay, _flushToDisk);
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
  ///
  /// For [LogLevel.warning] and above the write debounce is shortened to 50 ms
  /// so elevated-severity breadcrumbs reach disk quickly and survive a crash
  /// that happens in the window immediately after logging.
  void log(LogLevel level, String source, String message) {
    // Lazy one-shot file load; async-late completion is fine (load-once).
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
    _scheduleWrite(urgent: level.index >= LogLevel.warning.index);
    notifyListeners();
  }

  /// Force an immediate, synchronous-style flush of the in-memory buffer to
  /// disk with no debounce.  Intended to be called immediately before any
  /// operation that is known to risk crashing (e.g. entering a voice channel
  /// on iOS), guaranteeing that breadcrumbs written just before the call are
  /// on disk even if the process dies within milliseconds.
  ///
  /// Returns a [Future] that completes when the write finishes (or is skipped
  /// on web).  Callers that cannot await should use `.ignore()`.
  Future<void> forceFlush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    await _flushToDisk();
  }

  /// Write the in-memory buffer to disk using a **blocking** synchronous call.
  ///
  /// This is intentionally blocking I/O.  With [maxEntries] capped at 5000
  /// NDJSON lines the file is well under 1 MB and writes complete in <5 ms on
  /// iOS flash storage — an acceptable cost when the alternative is losing all
  /// breadcrumbs to a SIGKILL that fires before an async write round-trip can
  /// complete.
  ///
  /// Call order guarantees:
  /// 1. Any pending debounce timer is cancelled first to prevent a stale async
  ///    write from racing with this call and overwriting the file.
  /// 2. The write uses [_logFilePath] directly; if the path has not been
  ///    resolved yet (i.e. [_resolveLogFilePath] hasn't completed) the call
  ///    is a no-op — we cannot await in a sync context.
  /// 3. [IOException]s are swallowed silently: logging a log-write failure
  ///    would cause infinite recursion and the in-memory buffer remains intact.
  ///
  /// No-op on web ([kIsWeb] guard).
  void forceFlushSync() {
    if (kIsWeb) return;
    // Cancel the pending debounce timer so a later async write does not race.
    _writeTimer?.cancel();
    _writeTimer = null;
    // If the path hasn't been resolved yet we cannot block-wait for it.
    final path = _logFilePath;
    if (path == null) return;
    try {
      final snapshot = List<DebugLogEntry>.from(_entries);
      final lines = snapshot.map((e) => e.toJsonLine()).join('\n');
      File(path).writeAsStringSync('$lines\n');
    } on IOException catch (_) {
      // Swallow silently — see doc comment above.
    }
  }

  /// Read all persisted entries from the log file.
  ///
  /// Triggers the initial file load if it hasn't happened yet, then returns
  /// the current in-memory buffer.  On web, returns an empty list.
  Future<List<DebugLogEntry>> loadAllEntries() async {
    await _loadFromFile();
    return List.unmodifiable(_entries);
  }

  /// Format the most recent [n] entries as plaintext, one entry per line.
  ///
  /// Mirrors the format used by the in-app Debug Logs viewer
  /// (`HH:MM:SS [LVL] source: message`) so feedback reports and the viewer
  /// agree on layout. Returns an empty string when the buffer is empty.
  String tail(int n) {
    if (_entries.isEmpty || n <= 0) return '';
    final start = _entries.length > n ? _entries.length - n : 0;
    final buffer = StringBuffer();
    for (var i = start; i < _entries.length; i++) {
      final e = _entries[i];
      final h = e.timestamp.hour.toString().padLeft(2, '0');
      final m = e.timestamp.minute.toString().padLeft(2, '0');
      final s = e.timestamp.second.toString().padLeft(2, '0');
      final level = switch (e.level) {
        LogLevel.fine => 'FIN',
        LogLevel.info => 'INF',
        LogLevel.warning => 'WRN',
        LogLevel.error => 'ERR',
        LogLevel.fatal => 'FTL',
      };
      buffer.writeln('$h:$m:$s [$level] ${e.source}: ${e.message}');
    }
    return buffer.toString();
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
