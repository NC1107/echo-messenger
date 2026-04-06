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

  /// Unmodifiable snapshot of the current entries (oldest first).
  List<DebugLogEntry> get entries => List.unmodifiable(_entries);

  /// Append a new log entry, evicting the oldest if the buffer is full.
  void log(LogLevel level, String source, String message) {
    _entries.add(
      DebugLogEntry(
        timestamp: DateTime.now(),
        level: level,
        source: source,
        message: message,
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
