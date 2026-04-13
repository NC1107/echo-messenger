import 'package:flutter/foundation.dart';

/// Wrapper around [debugPrint] that silently no-ops in release builds.
///
/// Migrate production code from `debugPrint` to `debugLog` to avoid leaking
/// sensitive data (user IDs, tokens, session IDs) to system logs in release
/// mode.  In debug builds this delegates directly to [debugPrint].
void debugLog(String message, [String? tag]) {
  if (!kDebugMode) return;
  if (tag != null) {
    debugPrint('[$tag] $message');
  } else {
    debugPrint(message);
  }
}
