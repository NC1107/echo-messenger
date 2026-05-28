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
  Future<String?> _fetchWsTicketImpl() async {
    final serverUrl = ref.read(serverUrlProvider);
    // The crypto service may not be initialised yet on first connect.
    final crypto = ref.read(cryptoServiceProvider);
    final deviceId = crypto.isInitialized ? crypto.deviceId : 0;
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
      debugLog('Failed to fetch ws ticket: $e', 'WebSocket');
      DebugLogService.instance.log(
        LogLevel.error,
        'WebSocket',
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
