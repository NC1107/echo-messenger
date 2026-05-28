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
  ///
  /// Returns the ticket string on success, or null on failure. If the
  /// request returns 401, attempts to refresh the access token once and
  /// retries. Includes device_id in the request body for multi-device support.
  Future<String?> _fetchWsTicket() async {
    final serverUrl = ref.read(serverUrlProvider);
    // Include device_id in the ticket request for multi-device routing.
    // The crypto service may not be initialized yet on first connect.
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
      onDone: () {
        // Null these so the guard in _connectWithTicketOrFallback passes next time.
        _subscription = null;
        _channel = null;
        DebugLogService.instance.log(
          LogLevel.warning,
          'WebSocket',
          'Connection closed (onDone)',
        );
        // (#436) Mark peers offline; reconnect's presence_list reconciles.
        clearOnlineUsers();
        state = state.copyWith(isConnected: false);
        _scheduleReconnect();
      },
      onError: (_) {
        // Same cleanup as onDone.
        _subscription = null;
        _channel = null;
        DebugLogService.instance.log(
          LogLevel.error,
          'WebSocket',
          'Connection error (onError)',
        );
        // Same as onDone: clear stale presence before reconnect snapshot.
        clearOnlineUsers();
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

    final baseDelay = math.min(
      1000 * math.pow(2, _reconnectAttempts).toInt(),
      60000,
    );
    // Add jitter (0–50% of base) to avoid thundering herd after server restart
    final delayMs = baseDelay + _random.nextInt(math.max(baseDelay ~/ 2, 1));
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
  Future<void> sendMessage(
    String toUserId,
    String content, {
    String? conversationId,
    String? replyToId,
    String? threadRootId,
  }) async {
    final cryptoState = ref.read(cryptoProvider);
    if (!cryptoState.isInitialized) {
      final reason = cryptoState.error ?? 'Encryption not initialized';
      _addFailedMessage(
        toUserId,
        reason,
        conversationId: conversationId,
        originalContent: content,
      );
      return;
    }

    // If a previous key upload failed, retry now before sending.
    if (cryptoState.keysUploadFailed) {
      await ref.read(cryptoProvider.notifier).retryKeyUpload();
    }

    // (#522) Device IDs collide across users; keep per-recipient maps separate.
    final result = await _encryptMessageForSend(toUserId, content);
    if (result.payload == null) {
      _addFailedMessage(
        toUserId,
        _friendlyEncryptionError(result.error ?? 'Encryption failed'),
        conversationId: conversationId,
        originalContent: content,
      );
      return;
    }

    final (recipientDeviceContents, fallbackPayload) = result.payload!;
    _sendMessageFrame(
      toUserId,
      fallbackPayload,
      recipientDeviceContents,
      conversationId: conversationId,
      replyToId: replyToId,
      threadRootId: threadRootId,
    );
  }

  /// Encrypt a message for all devices (recipient + self) with fallback chain.
  /// Returns the encrypted payload on success, or the final error on total failure.
  Future<
    ({(Map<String, Map<String, String>>?, String)? payload, Object? error})
  >
  _encryptMessageForSend(String toUserId, String content) async {
    Map<String, Map<String, String>>? recipientDeviceContents;
    String fallbackPayload;
    try {
      final crypto = ref.read(cryptoServiceProvider);
      final token = ref.read(authProvider).token ?? '';
      crypto.setToken(token);

      final recipientContents = await crypto.encryptForAllDevices(
        toUserId,
        content,
      );

      final myUserId = ref.read(authProvider).userId;
      Map<String, String> selfContents = const {};
      if (myUserId != null && myUserId.isNotEmpty) {
        selfContents = await crypto.encryptForOwnDevices(myUserId, content);
      }

      recipientDeviceContents = _buildDeviceContentsMap(
        toUserId,
        recipientContents,
        myUserId,
        selfContents,
      );

      // Legacy fallback: prefer the recipient's first ciphertext over self.
      fallbackPayload =
          recipientContents.values.firstOrNull ??
          selfContents.values.firstOrNull ??
          '';

      return (payload: (recipientDeviceContents, fallbackPayload), error: null);
    } catch (e) {
      return _encryptMessageFallback(toUserId, content, e);
    }
  }

  /// Build the device contents map from recipient and self encryption results.
  Map<String, Map<String, String>>? _buildDeviceContentsMap(
    String toUserId,
    Map<String, String> recipientContents,
    String? myUserId,
    Map<String, String> selfContents,
  ) {
    final contents = <String, Map<String, String>>{};
    if (recipientContents.isNotEmpty) {
      contents[toUserId] = recipientContents;
    }
    if (selfContents.isNotEmpty && myUserId != null && myUserId.isNotEmpty) {
      contents[myUserId] = selfContents;
    }
    return contents;
  }

  /// Fallback encryption: try single-device, then session reset, then fail.
  Future<
    ({(Map<String, Map<String, String>>?, String)? payload, Object? error})
  >
  _encryptMessageFallback(
    String toUserId,
    String content,
    Object firstError,
  ) async {
    debugLog('Multi-device encryption failed: $firstError', 'WS');
    try {
      final crypto = ref.read(cryptoServiceProvider);
      final fallbackPayload = await crypto.encryptMessage(toUserId, content);
      return (payload: (null, fallbackPayload), error: null);
    } catch (e2) {
      debugLog('Fallback encryption failed, resetting session: $e2', 'WS');
      try {
        final crypto = ref.read(cryptoServiceProvider);
        await crypto.invalidateSessionKey(toUserId);
        final fallbackPayload = await crypto.encryptMessage(toUserId, content);
        return (payload: (null, fallbackPayload), error: null);
      } catch (e3) {
        debugLog('Encryption retry after reset also failed: $e3', 'WS');
        return (payload: null, error: e3);
      }
    }
  }

  /// Send the encrypted message frame over WebSocket with optional metadata.
  void _sendMessageFrame(
    String toUserId,
    String fallbackPayload,
    Map<String, Map<String, String>>? recipientDeviceContents, {
    String? conversationId,
    String? replyToId,
    String? threadRootId,
  }) {
    final msg = <String, dynamic>{
      'type': 'send_message',
      'to_user_id': toUserId,
      'content': fallbackPayload,
    };
    if (recipientDeviceContents != null && recipientDeviceContents.isNotEmpty) {
      msg['recipient_device_contents'] = recipientDeviceContents;
    }
    if (conversationId != null && conversationId.isNotEmpty) {
      msg['conversation_id'] = conversationId;
    }
    if (replyToId != null && replyToId.isNotEmpty) {
      msg['reply_to_id'] = replyToId;
    }
    if (threadRootId != null && threadRootId.isNotEmpty) {
      msg['thread_root_id'] = threadRootId;
    }

    _emit(msg);
  }

  /// Map raw encryption exceptions to user-readable messages.
  /// Never surfaces raw exception text — always returns a friendly string.
  static String _friendlyEncryptionError(Object e) {
    if (e is IdentityKeyChangedException) {
      return "This contact's identity has changed. "
          'Verify their safety number before sending.';
    }
    final msg = e.toString();
    if (msg.contains('No PreKey bundle found')) {
      return 'Waiting for this person to come online to secure the chat.';
    }
    if (msg.contains('Failed to fetch keys')) {
      return 'Message will send once the other person reconnects.';
    }
    if (msg.contains('Encryption not initialized')) {
      return 'Setting up your secure session \u2014 please try again in a moment.';
    }
    if (msg.contains('No session for')) {
      return 'Encryption session expired. Tap to retry.';
    }
    // #344: surfaced when sendGroupMessage cannot fetch the group key.
    if (msg.contains('No group session') || msg.contains('group key')) {
      return 'Group encryption key not available yet. Tap to retry.';
    }
    if (msg.contains('cannot decrypt') || msg.contains('Could not decrypt')) {
      return "Couldn't decrypt this message";
    }
    if (msg.contains('OTP key_id') && msg.contains('not found')) {
      return 'Encryption key mismatch. Ask the other person to resend.';
    }
    if (msg.contains('Auth expired')) {
      return 'Session expired. Please try again.';
    }
    return "Couldn't send · Tap to retry";
  }

  /// Add a failed message to the chat so the user can see the error.
  ///
  /// [originalContent] preserves the user's original text so it can be
  /// retried later without re-typing.
  void _addFailedMessage(
    String peerUserId,
    String reason, {
    String? conversationId = '',
    String? originalContent,
  }) {
    final auth = ref.read(authProvider);
    final myUserId = auth.userId ?? '';
    final myName = auth.username ?? 'You';
    final msg = ChatMessage(
      id: 'failed_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: myUserId,
      fromUsername: myName,
      conversationId: conversationId ?? '',
      content: reason,
      timestamp: DateTime.now().toIso8601String(),
      isMine: true,
      status: MessageStatus.failed,
      failedContent: originalContent,
    );
    ref.read(chatProvider.notifier).addMessage(msg);
  }

  /// Send a message to a group conversation.
  ///
  /// When the conversation is marked `isEncrypted=true`, encryption MUST
  /// succeed before the message goes on the wire.  If the group key is
  /// unavailable or encryption raises, the message surfaces as a failed
  /// `ChatMessage` (tap-to-retry via `_retryMessage`) and the WS frame is
  /// NOT sent.  This closes the silent plaintext downgrade vector (#344).
  /// Unencrypted groups (`isEncrypted=false`, the default) keep sending
  /// plaintext as before -- that path is intentional, not a downgrade.
  Future<void> sendGroupMessage(
    String conversationId,
    String content, {
    String? channelId,
    String? replyToId,
    String? threadRootId,
  }) async {
    final conversation = ref
        .read(conversationsProvider)
        .conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final isEncrypted = conversation?.isEncrypted ?? false;

    final String payload;
    // GRP2 binds (conv_id, msg_id) into the signature, so we mint msg_id
    // pre-encrypt; GRP1 leaves null and server mints.
    String? clientMessageId;
    if (isEncrypted) {
      final encrypted = await _encryptForGroupSend(
        conversationId: conversationId,
        content: content,
        conversation: conversation,
      );
      if (encrypted == null) {
        // Failure already enqueued via _addFailedMessage; do not send.
        return;
      }
      payload = encrypted.payload;
      clientMessageId = encrypted.clientMessageId;
    } else {
      payload = content;
    }

    _emit(
      _buildGroupSendFrame(
        conversationId: conversationId,
        payload: payload,
        clientMessageId: clientMessageId,
        channelId: channelId,
        replyToId: replyToId,
        threadRootId: threadRootId,
      ),
    );
  }

  /// Builds the JSON map sent over the wire for a group `send_message`.
  Map<String, dynamic> _buildGroupSendFrame({
    required String conversationId,
    required String payload,
    required String? clientMessageId,
    required String? channelId,
    required String? replyToId,
    required String? threadRootId,
  }) {
    final msg = <String, dynamic>{
      'type': 'send_message',
      'conversation_id': conversationId,
      'content': payload,
    };
    if (clientMessageId != null) {
      // Only set for GRP2 sends; server honours this id when storing.
      msg['client_message_id'] = clientMessageId;
    }
    if (channelId != null && channelId.isNotEmpty) {
      msg['channel_id'] = channelId;
    }
    if (replyToId != null && replyToId.isNotEmpty) {
      msg['reply_to_id'] = replyToId;
    }
    if (threadRootId != null && threadRootId.isNotEmpty) {
      msg['thread_root_id'] = threadRootId;
    }
    return msg;
  }

  /// Encrypts [content] for a group send. Returns `null` when encryption
  /// fails (and enqueues a failed-message placeholder for retry); callers
  /// must short-circuit in that case so plaintext never reaches the wire.
  Future<({String payload, String? clientMessageId})?> _encryptForGroupSend({
    required String conversationId,
    required String content,
    required Conversation? conversation,
  }) async {
    try {
      final groupCrypto = ref.read(groupCryptoServiceProvider);
      final token = ref.read(authProvider).token ?? '';
      groupCrypto.setToken(token);

      final keyResult = await _resolveGroupKeyWithSelfHeal(
        conversationId: conversationId,
        conversation: conversation,
        groupCrypto: groupCrypto,
      );
      if (keyResult == null) {
        // No group session yet -- hard fail rather than leak plaintext.
        _addFailedMessage(
          '',
          _friendlyEncryptionError('No group session'),
          conversationId: conversationId,
          originalContent: content,
        );
        return null;
      }
      final (_, keyBase64) = keyResult;

      // Phase 2D dispatch: GRP2 only when envelope's min_wire_version pins it.
      final minWireVersion =
          groupCrypto.cachedMinWireVersion(conversationId) ?? 1;
      if (minWireVersion >= 2) {
        return await _encryptGroupGrp2(
          conversationId: conversationId,
          content: content,
          keyBase64: keyBase64,
        );
      }
      final payload = await GroupCryptoService.encryptGroupMessage(
        content,
        keyBase64,
      );
      return (payload: payload, clientMessageId: null);
    } catch (e) {
      debugLog('Group encryption failed: $e', 'WebSocket');
      _addFailedMessage(
        '',
        _friendlyEncryptionError(e),
        conversationId: conversationId,
        originalContent: content,
      );
      return null;
    }
  }

  /// Looks up the cached group key, and if missing tries an owner/admin
  /// self-heal seed + refetch so a wedged envelope can recover without
  /// the user needing to tap a banner.
  Future<(int, String)?> _resolveGroupKeyWithSelfHeal({
    required String conversationId,
    required Conversation? conversation,
    required GroupCryptoService groupCrypto,
  }) async {
    var keyResult = await groupCrypto.getGroupKey(conversationId);
    if (keyResult != null) {
      return keyResult;
    }

    // Self-heal: owner/admin re-seeds wedged envelope (send-failures don't
    // bump receive-failure counter so banner never fires otherwise).
    if (!_isAdminOrOwnerOf(conversation)) {
      return null;
    }
    debugLog(
      'No usable group key for $conversationId — owner self-heal',
      'WebSocket',
    );
    await ref.read(cryptoProvider.notifier).seedInitialGroupKey(conversationId);
    keyResult = await groupCrypto.getGroupKey(conversationId);
    // TD-5: force fetch in case seedInitialGroupKey lost a 409 race.
    keyResult ??= await groupCrypto.fetchGroupKey(conversationId);
    return keyResult;
  }

  /// True when the current user is an owner/admin of [conversation].
  bool _isAdminOrOwnerOf(Conversation? conversation) {
    final myUserId = ref.read(authProvider).userId ?? '';
    final myMember = conversation?.members
        .where((m) => m.userId == myUserId)
        .firstOrNull;
    final role = myMember?.role;
    return role == 'owner' || role == 'admin';
  }

  /// Encrypts a GRP2 group send. Returns `null` (after enqueueing a
  /// failed-message placeholder) when the identity signing key isn't
  /// available — we refuse to silently downgrade to GRP1 because the
  /// envelope's min_wire_version is pinned to 2.
  Future<({String payload, String? clientMessageId})?> _encryptGroupGrp2({
    required String conversationId,
    required String content,
    required String keyBase64,
  }) async {
    final crypto = ref.read(cryptoServiceProvider);
    final signingKey = crypto.signingKeyPair;
    if (signingKey == null) {
      // No signing key yet (mid-init); GRP1 fallback would bounce off receiver's
      // min_wire_version guard, so fail typed instead.
      _addFailedMessage(
        '',
        _friendlyEncryptionError('Signing key unavailable for GRP2 send'),
        conversationId: conversationId,
        originalContent: content,
      );
      return null;
    }
    final convIdBytes = uuidStringToBytes(conversationId);
    final msgIdBytes = newUuidBytes();
    final clientMessageId = uuidBytesToString(msgIdBytes);
    final payload = await GroupCryptoService.encryptGroupMessageV2(
      plaintext: content,
      keyBase64: keyBase64,
      conversationIdBytes: convIdBytes,
      messageIdBytes: msgIdBytes,
      senderSigningKey: signingKey,
    );
    return (payload: payload, clientMessageId: clientMessageId);
  }

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
