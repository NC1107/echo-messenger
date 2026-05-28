part of '../websocket_provider.dart';

/// Receive-dispatcher slice of [WebSocketNotifier].
///
/// Top-level routing of a raw inbound WS frame: decode JSON, update the
/// last-message timestamp the heartbeat watchdog reads, then hand the
/// parsed envelope off to [WsMessageHandler.handleServerMessage] which
/// dispatches into the feature-grouped handler part files under
/// `ws_handlers/`.
///
/// The session-replaced teardown stays on the host class because it
/// touches the Notifier `state` setter (not visible from extensions in
/// this library) plus the connection fields owned by the lifecycle slice.
extension WsReceiveDispatcher on WebSocketNotifier {
  /// Decode a raw inbound WS payload and dispatch into the handler mixin.
  /// Returns the parsed JSON map so the host method can inspect post-
  /// dispatch state (e.g. session_replaced teardown).
  Map<String, dynamic> _decodeAndDispatchInbound(String data) {
    _lastMessageTime = DateTime.now();
    final json = jsonDecode(data) as Map<String, dynamic>;
    final myUserId = ref.read(authProvider).userId ?? '';
    handleServerMessage(json, myUserId);
    return json;
  }
}
