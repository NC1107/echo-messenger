import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import '../services/debug_log_service.dart';
import '../services/group_crypto_service.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'conversations_provider.dart';
import 'crypto_provider.dart';
import 'privacy_provider.dart';
import 'server_url_provider.dart';
import 'ws_message_handler.dart';

export 'ws_message_handler.dart' show WsMessageHandler, WebSocketState;

class WebSocketNotifier extends StateNotifier<WebSocketState>
    with WsMessageHandler {
  @override
  final Ref ref;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _typingCleanupTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  final _voiceSignalController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  StreamController<Map<String, dynamic>> get voiceSignalController =>
      _voiceSignalController;

  /// Throttle: track last typing event sent per conversation.
  final Map<String, DateTime> _lastTypingSent = {};

  /// Peers that already had a decrypt-retry this connection, to prevent
  /// cascading session invalidation.
  @override
  final Set<String> retriedPeers = {};

  WebSocketNotifier(this.ref) : super(const WebSocketState()) {
    // Periodically clean up stale typing indicators
    _typingCleanupTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _cleanupTyping(),
    );
  }

  Stream<Map<String, dynamic>> get voiceSignals =>
      _voiceSignalController.stream;

  /// Request a short-lived WebSocket ticket from the server.
  ///
  /// Returns the ticket string on success, or null on failure. If the
  /// request returns 401, attempts to refresh the access token once and
  /// retries.
  Future<String?> _fetchWsTicket() async {
    final serverUrl = ref.read(serverUrlProvider);
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
            ),
          );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['ticket'] as String?;
      }
    } catch (e) {
      debugPrint('[WebSocket] Failed to fetch ws ticket: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'WebSocket',
        'Failed to fetch ws ticket: $e',
      );
    }
    return null;
  }

  void connect() {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    disconnect();
    _reconnectAttempts = 0;

    // Attempt ticket-based connection, falling back to token-based for
    // backward compatibility with servers that don't support ws-ticket.
    _connectWithTicketOrFallback();
  }

  Future<void> _connectWithTicketOrFallback() async {
    final serverUrl = ref.read(serverUrlProvider);
    final wsBase = wsUrlFromHttpUrl(serverUrl);

    // Get a single-use WebSocket ticket (secure: JWT never in URL)
    final ticket = await _fetchWsTicket();

    if (ticket == null || ticket.isEmpty) {
      // Ticket fetch failed -- don't connect, schedule retry with backoff
      debugPrint('[WebSocket] Failed to obtain ticket, will retry...');
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
    _channel = WebSocketChannel.connect(uri);
    state = state.copyWith(isConnected: true);
    _reconnectAttempts = 0;
    retriedPeers.clear();
    DebugLogService.instance.log(
      LogLevel.info,
      'WebSocket',
      'Connected to $wsBase',
    );

    // Reload conversations now that WebSocket is connected -- ensures the
    // list is up-to-date even if the initial REST call raced with connection.
    ref.read(conversationsProvider.notifier).loadConversations();

    _subscription = _channel!.stream.listen(
      (data) => _onMessage(data as String),
      onDone: () {
        DebugLogService.instance.log(
          LogLevel.warning,
          'WebSocket',
          'Connection closed (onDone)',
        );
        state = state.copyWith(isConnected: false);
        _scheduleReconnect();
      },
      onError: (_) {
        DebugLogService.instance.log(
          LogLevel.error,
          'WebSocket',
          'Connection error (onError)',
        );
        state = state.copyWith(isConnected: false);
        _scheduleReconnect();
      },
    );
  }

  /// Schedule a reconnection attempt with exponential backoff.
  ///
  /// Uses `Timer` instead of `Future.delayed` so the pending callback can
  /// be cancelled in [disconnect] and [dispose].
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    if (!ref.read(authProvider).isLoggedIn) return;

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint(
        '[WebSocket] Max reconnect attempts ($_maxReconnectAttempts) '
        'reached -- server unreachable',
      );
      DebugLogService.instance.log(
        LogLevel.error,
        'WebSocket',
        'Max reconnect attempts ($_maxReconnectAttempts) reached',
      );
      state = state.copyWith(isConnected: false);
      return;
    }

    final delayMs = math.min(
      1000 * math.pow(2, _reconnectAttempts).toInt(),
      60000,
    );
    _reconnectAttempts++;
    debugPrint(
      '[WebSocket] Reconnecting in ${delayMs}ms '
      '(attempt $_reconnectAttempts/$_maxReconnectAttempts)',
    );
    DebugLogService.instance.log(
      LogLevel.info,
      'WebSocket',
      'Reconnecting in ${delayMs}ms '
          '(attempt $_reconnectAttempts/$_maxReconnectAttempts)',
    );

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (ref.read(authProvider).isLoggedIn) {
        _connectWithTicketOrFallback();
      }
    });
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    state = state.copyWith(isConnected: false);
    DebugLogService.instance.log(LogLevel.info, 'WebSocket', 'Disconnected');
  }

  /// Send a DM message to a peer.
  ///
  /// Direct messages are encrypted via the Signal Protocol. Encryption is
  /// attempted regardless of the conversation's isEncrypted flag to avoid
  /// blocking on newly created conversations where the flag may lag.
  Future<void> sendMessage(
    String toUserId,
    String content, {
    String? conversationId,
    String? replyToId,
  }) async {
    String payload;
    final cryptoState = ref.read(cryptoProvider);
    if (!cryptoState.isInitialized) {
      _addFailedMessage(
        toUserId,
        'Encryption not initialized',
        conversationId: conversationId,
      );
      return;
    }

    try {
      final crypto = ref.read(cryptoServiceProvider);
      final token = ref.read(authProvider).token ?? '';
      crypto.setToken(token);
      payload = await crypto.encryptMessage(toUserId, content);
    } catch (_) {
      _addFailedMessage(
        toUserId,
        'Encryption setup failed. Verify both users have encryption keys.',
        conversationId: conversationId,
      );
      return;
    }

    final msg = <String, dynamic>{
      'type': 'send_message',
      'to_user_id': toUserId,
      'content': payload,
    };
    if (conversationId != null && conversationId.isNotEmpty) {
      msg['conversation_id'] = conversationId;
    }
    if (replyToId != null && replyToId.isNotEmpty) {
      msg['reply_to_id'] = replyToId;
    }

    _channel?.sink.add(jsonEncode(msg));
  }

  /// Add a failed message to the chat so the user can see the error.
  void _addFailedMessage(
    String peerUserId,
    String reason, {
    String? conversationId = '',
  }) {
    final myUserId = ref.read(authProvider).userId ?? '';
    final msg = ChatMessage(
      id: 'failed_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: myUserId,
      fromUsername: 'You',
      conversationId: conversationId ?? '',
      content: reason,
      timestamp: DateTime.now().toIso8601String(),
      isMine: true,
      status: MessageStatus.failed,
    );
    ref.read(chatProvider.notifier).addMessage(msg);
  }

  /// Send a message to a group conversation.
  ///
  /// If the conversation has encryption enabled and a group encryption key is
  /// available, the message content is AES-256-GCM encrypted before being
  /// sent. Otherwise the message is sent as plaintext (backward compatible).
  Future<void> sendGroupMessage(
    String conversationId,
    String content, {
    String? channelId,
    String? replyToId,
  }) async {
    String payload = content;

    // Only attempt group encryption if the conversation is marked encrypted
    final conversation = ref
        .read(conversationsProvider)
        .conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final isEncrypted = conversation?.isEncrypted ?? false;

    if (isEncrypted) {
      try {
        final groupCrypto = ref.read(groupCryptoServiceProvider);
        final token = ref.read(authProvider).token ?? '';
        groupCrypto.setToken(token);
        final keyResult = await groupCrypto.getGroupKey(conversationId);
        if (keyResult != null) {
          final (_, keyBase64) = keyResult;
          payload = await GroupCryptoService.encryptGroupMessage(
            content,
            keyBase64,
          );
        }
      } catch (e) {
        debugPrint(
          '[WebSocket] Group encryption failed, sending plaintext: $e',
        );
      }
    }

    final msg = <String, dynamic>{
      'type': 'send_message',
      'conversation_id': conversationId,
      'content': payload,
    };
    if (channelId != null && channelId.isNotEmpty) {
      msg['channel_id'] = channelId;
    }
    if (replyToId != null && replyToId.isNotEmpty) {
      msg['reply_to_id'] = replyToId;
    }
    _channel?.sink.add(jsonEncode(msg));
  }

  /// Send a typing indicator (throttled to max 1 per 3 seconds per conversation).
  void sendTyping(String conversationId, {String? channelId}) {
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
    _channel?.sink.add(jsonEncode(msg));
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
    } catch (_) {}
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
    } catch (_) {}
  }

  /// Send a read receipt via WebSocket.
  void sendReadReceipt(String conversationId) {
    final privacy = ref.read(privacyProvider);
    if (!privacy.readReceiptsEnabled) {
      return;
    }
    _channel?.sink.add(
      jsonEncode({'type': 'read_receipt', 'conversation_id': conversationId}),
    );
  }

  /// Relay a WebRTC signaling payload to another voice-channel member.
  void sendVoiceSignal({
    required String conversationId,
    required String channelId,
    required String toUserId,
    required Map<String, dynamic> signal,
  }) {
    _channel?.sink.add(
      jsonEncode({
        'type': 'voice_signal',
        'conversation_id': conversationId,
        'channel_id': channelId,
        'to_user_id': toUserId,
        'signal': signal,
      }),
    );
  }

  void _onMessage(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    final myUserId = ref.read(authProvider).userId ?? '';
    handleServerMessage(json, myUserId);
  }

  /// Remove stale typing indicators (older than 5 seconds).
  void _cleanupTyping() {
    final now = DateTime.now();
    var changed = false;
    final updatedTyping = Map<String, Map<String, DateTime>>.from(
      state.typingUsers,
    );

    for (final conversationId in updatedTyping.keys.toList()) {
      final users = Map<String, DateTime>.from(updatedTyping[conversationId]!);
      final staleKeys = users.entries
          .where((e) => now.difference(e.value).inSeconds >= 5)
          .map((e) => e.key)
          .toList();
      for (final key in staleKeys) {
        users.remove(key);
        changed = true;
      }
      if (users.isEmpty) {
        updatedTyping.remove(conversationId);
      } else {
        updatedTyping[conversationId] = users;
      }
    }

    if (changed) {
      state = state.copyWith(typingUsers: updatedTyping);
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _typingCleanupTimer?.cancel();
    _voiceSignalController.close();
    disconnect();
    super.dispose();
  }
}

final websocketProvider =
    StateNotifierProvider<WebSocketNotifier, WebSocketState>((ref) {
      return WebSocketNotifier(ref);
    });
