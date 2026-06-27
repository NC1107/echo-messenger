part of '../websocket_provider.dart';

/// Connection lifecycle slice of [WebSocketNotifier].
///
/// Owns the helpers that don't need to write the Notifier `state` setter:
///  * ticket-fetch HTTP call
///  * exponential-backoff math (pure)
///  * channel-closed cleanup (resets transport fields then defers state
///    mutation back to the host class via the returned action)
///
/// The orchestrating methods (`connect`, `_connectWithTicketOrFallback`,
/// `_scheduleReconnect`, `_startHeartbeatMonitor`, `disconnect`) stay on
/// the host class because Dart extensions can't reach the Notifier
/// `state` setter across library boundaries.
extension WsLifecycle on WebSocketNotifier {
  /// Request a short-lived WebSocket ticket from the server. Returns the
  /// ticket string on success, or `null` on any failure (network, 401, …).
  /// Includes `device_id` in the body for multi-device routing.
  ///
  /// BUG #20 FIX: if the crypto service is not yet initialized, returning
  /// null here causes the caller to schedule a reconnect rather than
  /// connecting with device_id=0.  A device_id=0 ticket causes the server
  /// to record the canvas authority under device 0; once crypto initializes
  /// the client's real device_id is non-zero, making _canIWrite() return
  /// false for the rest of the session — drawing is permanently blocked on
  /// Android where crypto init is sometimes slower than the first WS
  /// connect attempt.  The reconnect fires quickly (first-attempt backoff
  /// is only 1s) and by then crypto is always initialized.
  Future<String?> _fetchWsTicketImpl() async {
    final serverUrl = ref.read(serverUrlProvider);
    final crypto = ref.read(cryptoServiceProvider);
    // Guard: do not connect until crypto is initialized. A device_id of 0
    // would mismatch the real device_id once crypto finishes, permanently
    // breaking the canvas write-authority check for this session (BUG #20).
    if (!crypto.isInitialized) {
      debugLog(
        'Crypto not yet initialized; deferring WS ticket fetch.',
        _kLogTag,
      );
      DebugLogService.instance.log(
        LogLevel.info,
        _kLogTag,
        'Crypto not initialized — deferring WS ticket fetch to avoid '
        'device_id=0 canvas authority mismatch (BUG #20).',
      );
      return null;
    }
    final deviceId = crypto.deviceId;
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse('$serverUrl/api/auth/ws-ticket'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({'device_id': deviceId}),
            ),
          );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['ticket'] as String?;
      }
    } catch (e) {
      debugLog('Failed to fetch ws ticket: $e', _kLogTag);
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'Failed to fetch ws ticket: $e',
      );
    }
    return null;
  }

  /// Tear down the transport-level fields after the stream's onDone/onError
  /// fires. The host method follows up with [clearOnlineUsers], a state
  /// write, and [_scheduleReconnect].
  void _resetTransportAfterDisconnect() {
    _subscription = null;
    _channel = null;
  }
}

/// Exponential backoff with 0-50% jitter, capped at 60s.
///
/// Pure helper extracted so the lifecycle slice's reconnect math is
/// unit-testable in isolation and so the orchestration in
/// `_scheduleReconnect` reads as a sequence rather than nested math.
int wsComputeBackoffMs(int attempt, math.Random random) {
  final baseDelay = math.min(1000 * math.pow(2, attempt).toInt(), 60000);
  return baseDelay + random.nextInt(math.max(baseDelay ~/ 2, 1));
}
