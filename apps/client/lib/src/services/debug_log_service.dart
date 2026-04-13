import 'package:flutter/foundation.dart';

/// Severity level for debug log entries.
enum LogLevel { info, warning, error }

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
}

/// Singleton service that captures debug log entries in a bounded ring buffer.
///
/// Mixes in [ChangeNotifier] so Settings UI widgets can listen for new entries
/// and rebuild automatically.
class DebugLogService with ChangeNotifier {
  DebugLogService._();

  static final instance = DebugLogService._();

  final _entries = <DebugLogEntry>[];

  /// Maximum number of entries retained before the oldest are dropped.
  static const maxEntries = 200;

  /// Matches standard UUIDs (8-4-4-4-12 hex).
  static final _uuidRegex = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );

  /// Unmodifiable snapshot of the current entries (oldest first).
  List<DebugLogEntry> get entries => List.unmodifiable(_entries);

  /// Truncate UUIDs to their first 8 hex characters to avoid leaking full
  /// user/conversation IDs into the in-memory log buffer that is visible
  /// from the Settings debug panel.
  String _redact(String msg) =>
      msg.replaceAllMapped(_uuidRegex, (m) => '${m[0]!.substring(0, 8)}...');

  /// Append a new log entry, evicting the oldest if the buffer is full.
  ///
  /// UUIDs in [message] are automatically truncated to prevent leaking full
  /// identifiers into the debug log buffer.
  void log(LogLevel level, String source, String message) {
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
    notifyListeners();
  }

  /// Remove all stored entries.
  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
