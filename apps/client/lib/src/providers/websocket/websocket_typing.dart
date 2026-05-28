part of '../websocket_provider.dart';

/// Typing-indicator slice of [WebSocketNotifier].
///
/// Owns:
///  * `sendTyping` (outbound, throttled)
///  * `_cleanupTyping` (periodic prune of inbound + outbound throttle map)
///
/// The throttle-state field `_lastTypingSent` and the periodic
/// `_typingCleanupTimer` are declared on the host class because Dart
/// extensions cannot add instance fields, but every read/write of them
/// lives here so this file is the single source of truth for the slice.
extension WsTyping on WebSocketNotifier {
  /// Send a typing indicator (throttled to max 1 per 3 seconds per conversation).
  void _sendTypingImpl(String conversationId, {String? channelId}) {
    final throttleKey = '$conversationId:${channelId ?? ''}';
    final now = DateTime.now();
    final lastSent = _lastTypingSent[throttleKey];
    if (lastSent != null && now.difference(lastSent).inSeconds < 3) {
      return;
    }
    _lastTypingSent[throttleKey] = now;

    final msg = <String, dynamic>{
      'type': 'typing',
      'conversation_id': conversationId,
    };
    if (channelId != null && channelId.isNotEmpty) {
      msg['channel_id'] = channelId;
    }
    _emit(msg);
  }

  /// Prune our own outbound `_lastTypingSent` throttle entries (> 10s old).
  /// Audit 2026-05-12 finding #9: bounded growth across long sessions.
  void _pruneTypingThrottle() {
    final now = DateTime.now();
    final staleThrottleKeys = _lastTypingSent.entries
        .where((e) => now.difference(e.value).inSeconds > 10)
        .map((e) => e.key)
        .toList();
    for (final key in staleThrottleKeys) {
      _lastTypingSent.remove(key);
    }
  }
}

/// Compute a new typing-users map with entries older than 5 seconds dropped.
///
/// Returns `null` when nothing changed (caller should skip the state write
/// to avoid spurious rebuilds). Extracted as a pure free function so it can
/// be unit-tested in isolation and lives in the same file as the rest of
/// the typing slice.
Map<String, Map<String, DateTime>>? _pruneStaleTyping(
  Map<String, Map<String, DateTime>> input,
) {
  final updated = Map<String, Map<String, DateTime>>.from(input);
  final now = DateTime.now();
  var changed = false;

  for (final conversationId in updated.keys.toList()) {
    final users = Map<String, DateTime>.from(updated[conversationId]!);
    final staleKeys = users.entries
        .where((e) => now.difference(e.value).inSeconds >= 5)
        .map((e) => e.key)
        .toList();
    for (final key in staleKeys) {
      users.remove(key);
      changed = true;
    }
    if (users.isEmpty) {
      updated.remove(conversationId);
    } else {
      updated[conversationId] = users;
    }
  }

  return changed ? updated : null;
}
