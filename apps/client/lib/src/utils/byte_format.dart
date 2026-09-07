/// Format a byte count as a human-readable string (1024-based, 1 decimal):
/// "512 B", "1.2 KB", "3.4 MB", "5.6 GB".
///
/// Single source of truth — callers used to hand-roll this three times, one of
/// which silently stopped at MB and showed huge "1234.5 MB" values for caches
/// over a gigabyte.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024.0;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}
