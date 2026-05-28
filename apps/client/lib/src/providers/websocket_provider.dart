import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../services/crypto_service.dart' show IdentityKeyChangedException;
import '../services/debug_log_service.dart';
import '../services/group_crypto_service.dart';
import '../utils/debug_log.dart';
import '../utils/uuid_bytes.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'conversations_provider.dart';
import 'crypto_provider.dart';
import 'privacy_provider.dart';
import 'server_url_provider.dart';
import 'ws_message_handler.dart';

export 'ws_message_handler.dart' show WsMessageHandler, WebSocketState;

part 'websocket_provider.g.dart';
part 'websocket/websocket_typing.dart';
part 'websocket/websocket_receive_dispatcher.dart';
part 'websocket/websocket_lifecycle.dart';
part 'websocket/websocket_send.dart';

@Riverpod(keepAlive: true)
class WebSocketNotifier extends _$WebSocketNotifier with WsMessageHandler {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _typingCleanupTimer;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  DateTime _lastMessageTime = DateTime.now();
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 1000; // effectively unlimited
  final _random = math.Random();
  final _voiceSignalController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _deviceRevokedController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  StreamController<Map<String, dynamic>> get voiceSignalController =>
      _voiceSignalController;

  @override
  StreamController<Map<String, dynamic>> get deviceRevokedController =>
      _deviceRevokedController;

  /// Stream of `device_revoked` events for the authenticated user.
  Stream<Map<String, dynamic>> get deviceRevokedEvents =>
      _deviceRevokedController.stream;

  /// Throttle: track last typing event sent per conversation.
  final Map<String, DateTime> _lastTypingSent = {};

  /// Test-visible log of every frame emitted via [_emit]. Empty in production
  /// (write-only via [_emit]); tests can read it to assert wire shape without
  /// having to inject a fake [WebSocketChannel].
  @visibleForTesting
  final List<Map<String, dynamic>> debugSentFrames = [];

  /// Centralised emit hook: every WS frame the client sends goes through here
  /// so wire-shape contract tests have one place to assert against. This must
  /// remain behaviorally identical to a direct `_channel?.sink.add(jsonEncode(frame))`.
  void _emit(Map<String, dynamic> frame) {
    debugSentFrames.add(frame);
    _channel?.sink.add(jsonEncode(frame));
  }

  @override
  WebSocketState build() {
    // Periodically clean up stale typing indicators.
    _typingCleanupTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _cleanupTyping(),
    );

    // (#PR-2) Re-bind WS on server URL change; old origin must not see any frames.
    ref.listen<String>(serverUrlProvider, (previous, next) {
      if (previous == next) return;
      disconnect();
      // Login flow calls connect() itself if not yet authenticated.
      if (ref.read(authProvider).isLoggedIn) {
        connect();
      }
    });

    // Mirror the legacy `dispose()` teardown.
    ref.onDispose(() {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _typingCleanupTimer?.cancel();
      _voiceSignalController.close();
      _deviceRevokedController.close();
      disconnect();
    });

    return const WebSocketState();
  }

  Stream<Map<String, dynamic>> get voiceSignals =>
      _voiceSignalController.stream;

  /// Request a short-lived WebSocket ticket from the server.
  /// Implementation in `websocket/websocket_lifecycle.dart`.
  Future<String?> _fetchWsTicket() => _fetchWsTicketImpl();

  void connect() {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    // (#830) Cancel pending reconnect — backoff fire would race connect into 2 channels.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    disconnect();
    _reconnectAttempts = 0;
    // wasReplaced is intentionally NOT cleared here. Only [reconnectAfterReplacement]
    // resets it, which is called explicitly by the user dismissing the banner.
    _connectWithTicketOrFallback();
  }

  /// Called when the user acknowledges a session-replaced banner and requests
  /// a fresh connection. Clears [wasReplaced] so the banner disappears and
  /// auto-reconnect resumes normally.
  void reconnectAfterReplacement() {
    state = state.copyWith(wasReplaced: false);
    connect();
  }

  Future<void> _connectWithTicketOrFallback() async {
    // Non-null channel = active or mid-connect; prevents parallel channels.
    if (_channel != null) {
      return;
    }

    final serverUrl = ref.read(serverUrlProvider);
    final wsBase = wsUrlFromHttpUrl(serverUrl);

    // Get a single-use WebSocket ticket (secure: JWT never in URL)
    final ticket = await _fetchWsTicket();

    if (ticket == null || ticket.isEmpty) {
      // Ticket fetch failed -- don't connect, schedule retry with backoff
      debugLog('Failed to obtain ticket, will retry...', 'WebSocket');
      DebugLogService.instance.log(
        LogLevel.warning,
        'WebSocket',
        'Failed to obtain ticket, will retry...',
      );
      state = state.copyWith(isConnected: false);
      _scheduleReconnect();
      return;
    }

    final uri = Uri.parse('$wsBase/ws?ticket=$ticket');

    try {
      _channel = WebSocketChannel.connect(uri);
    } catch (e) {
      // WebSocketChannel.connect can throw sync (invalid URI on web, mixed-content);
      // don't leave isConnected=true without a channel.
      debugPrint('[WebSocket] connect() threw: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'WebSocket',
        'Connection failed: $e',
      );
      state = state.copyWith(isConnected: false);
      _scheduleReconnect();
      return;
    }

    state = state.copyWith(isConnected: true, reconnectAttempts: 0);
    _reconnectAttempts = 0;
    DebugLogService.instance.log(
      LogLevel.info,
      'WebSocket',
      'Connected to $wsBase',
    );

    // Suppress notification toasts for the first few seconds after connect
    // so backfilled messages don't spam the user on login / reconnect
    // (2026-05-27 feedback). Reset on every connect so a long-disconnected
    // device coming back online doesn't re-spam either.
    openInitialSyncWindow();

    // Reload conversations in case initial REST raced with the WS connect.
    ref.read(conversationsProvider.notifier).loadConversations();

    _lastMessageTime = DateTime.now();
    _startHeartbeatMonitor();

    _subscription = _channel!.stream.listen(
      (data) => _onMessage(data as String),
      onDone: () => _handleChannelClosed(
        level: LogLevel.warning,
        message: 'Connection closed (onDone)',
      ),
      onError: (_) => _handleChannelClosed(
        level: LogLevel.error,
        message: 'Connection error (onError)',
      ),
    );
  }

  /// Shared onDone/onError teardown: reset transport, log, clear peer
  /// presence (#436), drop `isConnected`, and schedule a reconnect.
  void _handleChannelClosed({
    required LogLevel level,
    required String message,
  }) {
    _resetTransportAfterDisconnect();
    DebugLogService.instance.log(level, 'WebSocket', message);
    clearOnlineUsers();
    state = state.copyWith(isConnected: false);
    _scheduleReconnect();
  }

  /// Schedule a reconnection attempt with exponential backoff.
  ///
  /// Uses `Timer` instead of `Future.delayed` so the pending callback can
  /// be cancelled in [disconnect] and [dispose].
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Do not reconnect if this session was replaced by another device/tab.
    if (state.wasReplaced) return;

    if (!ref.read(authProvider).isLoggedIn) return;

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugLog(
        'Max reconnect attempts ($_maxReconnectAttempts) '
            'reached -- server unreachable',
        'WebSocket',
      );
      DebugLogService.instance.log(
        LogLevel.error,
        'WebSocket',
        'Max reconnect attempts ($_maxReconnectAttempts) reached',
      );
      state = state.copyWith(
        isConnected: false,
        reconnectAttempts: _reconnectAttempts,
      );
      return;
    }

    // Backoff math (exponential + 0-50% jitter, capped 60s) lives in
    // websocket/websocket_lifecycle.dart so it's testable in isolation.
    final delayMs = wsComputeBackoffMs(_reconnectAttempts, _random);
    _reconnectAttempts++;
    state = state.copyWith(reconnectAttempts: _reconnectAttempts);

    // Skip log on first reconnect (normal after drop); only log retries.
    if (_reconnectAttempts > 1) {
      debugLog(
        'Reconnecting in ${delayMs}ms '
            '(attempt $_reconnectAttempts/$_maxReconnectAttempts)',
        'WebSocket',
      );
      DebugLogService.instance.log(
        LogLevel.info,
        'WebSocket',
        'Reconnecting in ${delayMs}ms '
            '(attempt $_reconnectAttempts/$_maxReconnectAttempts)',
      );
    }

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (ref.read(authProvider).isLoggedIn) {
        _connectWithTicketOrFallback();
      }
    });
  }

  void disconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    // Clear queued messages to prevent leaks on reconnect to different account
    clearPendingDecryptQueue();
    state = state.copyWith(isConnected: false);
    DebugLogService.instance.log(LogLevel.info, 'WebSocket', 'Disconnected');
  }

  /// Send a DM message to a peer.
  ///
  /// Direct messages are encrypted via the Signal Protocol. Encryption is
  /// attempted regardless of the conversation's isEncrypted flag to avoid
  /// blocking on newly created conversations where the flag may lag.
  /// Implementation lives in `websocket/websocket_send.dart`.
  Future<void> sendMessage(
    String toUserId,
    String content, {
    String? conversationId,
    String? replyToId,
    String? threadRootId,
  }) => _sendDmMessage(
    toUserId,
    content,
    conversationId: conversationId,
    replyToId: replyToId,
    threadRootId: threadRootId,
  );

  // Encryption fallback chain, device-contents map, frame builder,
  // friendly-error mapping, failed-message helper, and the full group send
  // pipeline (sendGroupMessage entry below) all live in
  // `websocket/websocket_send.dart`. Keeping them in one file lets the
  // wire-shape contract tests verify both 1:1 and group bytes in lockstep
  // and keeps the host class focused on the Notifier `state` setter, which
  // the send path doesn't touch.

  // (encryption helpers, device-contents builder, fallback chain, and
  // frame-builder all live in `websocket/websocket_send.dart`)

  /// Send a message to a group conversation.
  ///
  /// When the conversation is marked `isEncrypted=true`, encryption MUST
  /// succeed before the message goes on the wire.  If the group key is
  /// unavailable or encryption raises, the message surfaces as a failed
  /// `ChatMessage` (tap-to-retry via `_retryMessage`) and the WS frame is
  /// NOT sent.  This closes the silent plaintext downgrade vector (#344).
  /// Unencrypted groups (`isEncrypted=false`, the default) keep sending
  /// plaintext as before -- that path is intentional, not a downgrade.
  /// Implementation lives in `websocket/websocket_send.dart`.
  Future<void> sendGroupMessage(
    String conversationId,
    String content, {
    String? channelId,
    String? replyToId,
    String? threadRootId,
  }) => _sendGroupMessage(
    conversationId,
    content,
    channelId: channelId,
    replyToId: replyToId,
    threadRootId: threadRootId,
  );

  /// Send a typing indicator (throttled to max 1 per 3 seconds per conversation).
  /// Implementation lives in `websocket/websocket_typing.dart` so the
  /// throttle map + cleanup timer have a single owner file.
  void sendTyping(String conversationId, {String? channelId}) =>
      _sendTypingImpl(conversationId, channelId: channelId);

  /// Notify the peer that encryption keys were reset for this conversation.
  void sendKeyReset(String conversationId) {
    _emit({'type': 'key_reset', 'conversation_id': conversationId});
  }

  /// Notify conversation members that a voice call was started.
  void sendCallStarted(String conversationId) {
    _emit({'type': 'call_started', 'conversation_id': conversationId});
  }

  /// Send a reaction via REST (server broadcasts via WebSocket to other members).
  Future<void> sendReaction(
    String conversationId,
    String messageId,
    String emoji,
  ) async {
    final serverUrl = ref.read(serverUrlProvider);
    try {
      await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse('$serverUrl/api/messages/$messageId/reactions'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({'emoji': emoji}),
            ),
          );
    } catch (e) {
      debugLog('sendReaction error: $e', 'WebSocket');
    }
  }

  /// Remove a reaction via REST.
  Future<void> removeReaction(
    String conversationId,
    String messageId,
    String emoji,
  ) async {
    final serverUrl = ref.read(serverUrlProvider);
    try {
      await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse('$serverUrl/api/messages/$messageId/reactions/$emoji'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
    } catch (e) {
      debugLog('removeReaction error: $e', 'WebSocket');
    }
  }

  /// Send a read receipt via WebSocket.
  void sendReadReceipt(String conversationId) {
    final privacy = ref.read(privacyProvider);
    if (!privacy.readReceiptsEnabled) {
      return;
    }
    _emit({'type': 'read_receipt', 'conversation_id': conversationId});
  }

  /// Relay a WebRTC signaling payload to another voice-channel member.
  void sendVoiceSignal({
    required String conversationId,
    required String channelId,
    required String toUserId,
    required Map<String, dynamic> signal,
  }) {
    _emit({
      'type': 'voice_signal',
      'conversation_id': conversationId,
      'channel_id': channelId,
      'to_user_id': toUserId,
      'signal': signal,
    });
  }

  /// Broadcast a voice-lounge canvas event to all conversation members.
  void sendCanvasEvent({
    required String channelId,
    required String kind,
    required Map<String, dynamic> payload,
  }) {
    _emit({
      'type': 'canvas_event',
      'channel_id': channelId,
      'kind': kind,
      'payload': payload,
    });
  }

  /// Start a periodic timer that checks whether the server has gone silent.
  ///
  /// If no message (including Pong frames surfaced as data) arrives within
  /// 60 seconds, the connection is assumed dead and a reconnect is triggered.
  /// The server sends Ping frames every 30 s, so under normal conditions we
  /// receive traffic well within the 60 s window.
  void _startHeartbeatMonitor() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final elapsed = DateTime.now().difference(_lastMessageTime);
      if (elapsed.inSeconds > 60) {
        DebugLogService.instance.log(
          LogLevel.warning,
          'WebSocket',
          'Heartbeat timeout (${elapsed.inSeconds}s since last message)',
        );
        disconnect();
        _scheduleReconnect();
      }
    });
  }

  /// Stream listener entry point. Decoding + dispatch is in
  /// `websocket/websocket_receive_dispatcher.dart`; this wrapper retains
  /// the post-dispatch session-replaced teardown because it touches the
  /// Notifier `state` setter and the lifecycle-owned connection fields.
  void _onMessage(String data) {
    _decodeAndDispatchInbound(data);

    // session_replaced: disconnect, do NOT auto-reconnect (other session is active).
    if (state.wasReplaced) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _subscription?.cancel();
      _channel?.sink.close();
      _channel = null;
    }
  }

  /// Periodic typing-state pruning. Pure prune logic + outbound throttle prune
  /// live in `websocket/websocket_typing.dart`; only the state assignment
  /// stays here because the Notifier `state` setter is not visible to
  /// extensions in this library.
  void _cleanupTyping() {
    final pruned = _pruneStaleTyping(state.typingUsers);
    if (pruned != null) {
      state = state.copyWith(typingUsers: pruned);
    }
    _pruneTypingThrottle();
  }
}

/// Short alias matching the historical provider symbol.  Codegen names
/// the generated provider after the class (`webSocketNotifierProvider`),
/// but the rest of the codebase has always referenced this as
/// `websocketProvider`; the alias avoids a cross-cutting rename that's
/// orthogonal to the migration.
final websocketProvider = webSocketNotifierProvider;
