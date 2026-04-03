import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../services/crypto_service.dart';
import '../services/notification_service.dart';
import '../services/sound_service.dart';
import '../utils/crypto_utils.dart';
import 'auth_provider.dart';
import 'channels_provider.dart';
import 'chat_provider.dart';
import 'conversations_provider.dart';
import 'crypto_provider.dart';
import 'privacy_provider.dart';
import 'server_url_provider.dart';

/// State that tracks both connection status and typing indicators.
class WebSocketState {
  final bool isConnected;

  /// Map of conversationId -> set of usernames currently typing.
  final Map<String, Map<String, DateTime>> typingUsers;

  /// Set of user IDs currently known to be online (from presence events).
  final Set<String> onlineUsers;

  const WebSocketState({
    this.isConnected = false,
    this.typingUsers = const {},
    this.onlineUsers = const {},
  });

  WebSocketState copyWith({
    bool? isConnected,
    Map<String, Map<String, DateTime>>? typingUsers,
    Set<String>? onlineUsers,
  }) {
    return WebSocketState(
      isConnected: isConnected ?? this.isConnected,
      typingUsers: typingUsers ?? this.typingUsers,
      onlineUsers: onlineUsers ?? this.onlineUsers,
    );
  }

  /// Check if a specific user is online.
  bool isUserOnline(String userId) => onlineUsers.contains(userId);

  String _typingKey(String conversationId, String? channelId) {
    return '$conversationId:${channelId ?? ''}';
  }

  /// Get list of usernames typing in a given conversation/channel.
  List<String> typingIn(String conversationId, {String? channelId}) {
    final users = typingUsers[_typingKey(conversationId, channelId)];
    if (users == null) return [];
    final now = DateTime.now();
    // Only show users who typed within the last 5 seconds
    return users.entries
        .where((e) => now.difference(e.value).inSeconds < 5)
        .map((e) => e.key)
        .toList();
  }
}

class WebSocketNotifier extends StateNotifier<WebSocketState> {
  final Ref ref;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _typingCleanupTimer;
  final _voiceSignalController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Throttle: track last typing event sent per conversation.
  final Map<String, DateTime> _lastTypingSent = {};

  /// Peers that already had a decrypt-retry this connection, to prevent
  /// cascading session invalidation.
  final Set<String> _retriedPeers = {};

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
    }
    return null;
  }

  void connect() {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    disconnect();

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
      // Ticket fetch failed -- don't connect, let reconnect timer retry
      debugPrint('[WebSocket] Failed to obtain ticket, will retry...');
      state = state.copyWith(isConnected: false);
      return;
    }

    final uri = Uri.parse('$wsBase/ws?ticket=$ticket');
    _channel = WebSocketChannel.connect(uri);
    state = state.copyWith(isConnected: true);
    _retriedPeers.clear();

    // Reload conversations now that WebSocket is connected -- ensures the
    // list is up-to-date even if the initial REST call raced with connection.
    ref.read(conversationsProvider.notifier).loadConversations();

    _subscription = _channel!.stream.listen(
      (data) => _onMessage(data as String),
      onDone: () {
        state = state.copyWith(isConnected: false);
        Future.delayed(const Duration(seconds: 3), () {
          if (ref.read(authProvider).isLoggedIn) connect();
        });
      },
      onError: (_) => state = state.copyWith(isConnected: false),
    );
  }

  void disconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    state = state.copyWith(isConnected: false);
  }

  /// Send a DM message to a peer. Encrypts only if the conversation has
  /// encryption enabled; otherwise sends plaintext.
  Future<void> sendMessage(
    String toUserId,
    String content, {
    String? conversationId,
  }) async {
    // Check if encryption is enabled for this conversation.
    final isEncrypted =
        conversationId != null &&
        ref
                .read(conversationsProvider)
                .conversations
                .where((c) => c.id == conversationId)
                .firstOrNull
                ?.isEncrypted ==
            true;

    final privacy = ref.read(privacyProvider);
    if (!isEncrypted && !privacy.allowUnencryptedDm) {
      _addFailedMessage(
        toUserId,
        'Plaintext direct messages are disabled in privacy settings',
        conversationId: conversationId ?? '',
      );
      return;
    }

    String payload;
    if (isEncrypted) {
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
          'Encryption setup failed. Recipient may not have encryption keys. Try disabling encryption.',
          conversationId: conversationId,
        );
        return;
      }
    } else {
      payload = content;
    }

    final msg = <String, dynamic>{
      'type': 'send_message',
      'to_user_id': toUserId,
      'content': payload,
    };
    if (conversationId != null && conversationId.isNotEmpty) {
      msg['conversation_id'] = conversationId;
    }

    _channel?.sink.add(jsonEncode(msg));
  }

  /// Add a failed message to the chat so the user can see the error.
  void _addFailedMessage(
    String peerUserId,
    String reason, {
    String conversationId = '',
  }) {
    final myUserId = ref.read(authProvider).userId ?? '';
    final msg = ChatMessage(
      id: 'failed_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: myUserId,
      fromUsername: 'You',
      conversationId: conversationId,
      content: reason,
      timestamp: DateTime.now().toIso8601String(),
      isMine: true,
      status: MessageStatus.failed,
    );
    ref.read(chatProvider.notifier).addMessage(msg);
  }

  /// Send a message to a group conversation.
  Future<void> sendGroupMessage(
    String conversationId,
    String content, {
    String? channelId,
  }) async {
    final msg = <String, dynamic>{
      'type': 'send_message',
      'conversation_id': conversationId,
      'content': content,
    };
    if (channelId != null && channelId.isNotEmpty) {
      msg['channel_id'] = channelId;
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
    final type = json['type'] as String;
    final myUserId = ref.read(authProvider).userId ?? '';

    switch (type) {
      case 'new_message':
        _handleNewMessage(json, myUserId);
      case 'message_sent':
        _handleMessageSent(json);
      case 'typing':
        _handleTyping(json, myUserId);
      case 'reaction':
        final action = json['action'] as String?;
        if (action == 'remove') {
          _handleRemoveReaction(json);
        } else {
          _handleReaction(json);
        }
      case 'delivered':
        _handleDelivered(json);
      case 'read_receipt':
        _handleReadReceipt(json);
      case 'message_deleted':
        _handleMessageDeleted(json);
      case 'message_edited':
        _handleMessageEdited(json);
      case 'encryption_toggled':
        _handleEncryptionToggled(json);
      case 'presence':
        _handlePresence(json);
      case 'presence_list':
        _handlePresenceList(json);
      case 'channel_created':
      case 'channel_updated':
      case 'channel_deleted':
        _refreshChannelsFromEvent(json);
      case 'voice_session_joined':
      case 'voice_session_left':
      case 'voice_session_updated':
        _refreshVoiceSessionsFromEvent(json);
      case 'mention':
        _handleMention(json, myUserId);
      case 'error':
        break;
      case 'voice_signal':
        _handleVoiceSignal(json);
    }
  }

  void _handleVoiceSignal(Map<String, dynamic> json) {
    _voiceSignalController.add(json);
  }

  void _refreshChannelsFromEvent(Map<String, dynamic> json) {
    final groupId = json['group_id'] as String?;
    if (groupId == null || groupId.isEmpty) return;
    ref.read(channelsProvider.notifier).loadChannels(groupId);
  }

  void _refreshVoiceSessionsFromEvent(Map<String, dynamic> json) {
    final groupId = json['group_id'] as String?;
    final channelId = json['channel_id'] as String?;
    if (groupId == null || channelId == null) return;

    final notifier = ref.read(channelsProvider.notifier);
    notifier.loadVoiceSessions(groupId, channelId);
  }

  void _handleMessageSent(Map<String, dynamic> json) {
    final messageId = json['message_id'] as String;
    final conversationId = json['conversation_id'] as String;
    final channelId = json['channel_id'] as String?;
    final timestamp = json['timestamp'] as String;
    ref
        .read(chatProvider.notifier)
        .confirmSent(
          messageId,
          conversationId,
          timestamp,
          channelId: channelId,
        );
    // Update status to sent
    ref
        .read(chatProvider.notifier)
        .updateMessageStatus(conversationId, messageId, MessageStatus.sent);
  }

  void _handleNewMessage(Map<String, dynamic> json, String myUserId) {
    final rawContent = json['content'] as String;
    final fromUserId = json['from_user_id'] as String;
    final conversationId = json['conversation_id'] as String;
    final timestamp = json['timestamp'] as String;
    final senderUsername = json['from_username'] as String;
    final cryptoState = ref.read(cryptoProvider);

    // Check if this conversation is already known locally
    final isKnownConversation = ref
        .read(conversationsProvider)
        .conversations
        .any((c) => c.id == conversationId);

    if (cryptoState.isInitialized) {
      final crypto = ref.read(cryptoServiceProvider);
      final token = ref.read(authProvider).token ?? '';
      crypto.setToken(token);
      _decryptAndDeliverWithPreview(
        crypto,
        json,
        rawContent,
        fromUserId,
        myUserId,
        conversationId,
        timestamp,
        senderUsername,
      );
    } else {
      final msg = ChatMessage.fromServerJson(json, myUserId);
      ref.read(chatProvider.notifier).addMessage(msg);

      // Update conversations list with raw content
      ref
          .read(conversationsProvider.notifier)
          .onNewMessage(
            conversationId: conversationId,
            content: rawContent,
            timestamp: timestamp,
            senderUsername: senderUsername,
          );
    }

    // Only do a full HTTP reload if this is a new conversation we don't have
    // locally. For existing conversations, onNewMessage() already updates state.
    if (!isKnownConversation) {
      ref.read(conversationsProvider.notifier).loadConversations();
    }

    // Play notification sound and show push notification for incoming messages
    if (fromUserId != myUserId) {
      SoundService().playMessageReceived();
      // Fire browser/desktop notification (only shows when app not focused)
      NotificationService().showMessageNotification(
        senderUsername: senderUsername,
        body: rawContent.length > 100
            ? '${rawContent.substring(0, 100)}...'
            : rawContent,
      );
    }
  }

  Future<void> _decryptAndDeliverWithPreview(
    CryptoService crypto,
    Map<String, dynamic> json,
    String rawContent,
    String fromUserId,
    String myUserId,
    String conversationId,
    String timestamp,
    String senderUsername,
  ) async {
    String decryptedContent;
    final wasEncrypted = looksEncrypted(rawContent);

    if (!wasEncrypted) {
      // Content does not look encrypted (e.g. plaintext group messages) --
      // deliver as-is without attempting decryption.
      decryptedContent = rawContent;
    } else {
      try {
        decryptedContent = await crypto.decryptMessage(fromUserId, rawContent);
      } catch (firstError) {
        if (!_retriedPeers.contains(fromUserId)) {
          // First failure for this peer this connection -- invalidate session
          // and retry once.
          _retriedPeers.add(fromUserId);
          try {
            await crypto.invalidateSessionKey(fromUserId);
            decryptedContent = await crypto.decryptMessage(
              fromUserId,
              rawContent,
            );
          } catch (retryError) {
            debugPrint(
              '[WebSocket] Decryption failed for message in $conversationId '
              'from $fromUserId. First error: $firstError, '
              'Retry error: $retryError',
            );
            decryptedContent =
                '[Could not decrypt - encryption keys may be out of sync]';
          }
        } else {
          debugPrint(
            '[WebSocket] Skipping retry for $fromUserId '
            '(already retried this connection): $firstError',
          );
          decryptedContent =
              '[Could not decrypt - encryption keys may be out of sync]';
        }
      }
    }

    final decryptedJson = Map<String, dynamic>.from(json);
    decryptedJson['content'] = decryptedContent;
    var msg = ChatMessage.fromServerJson(decryptedJson, myUserId);
    if (wasEncrypted) {
      msg = msg.copyWith(isEncrypted: true);
    }
    ref.read(chatProvider.notifier).addMessage(msg);

    // Update conversations list with decrypted preview
    ref
        .read(conversationsProvider.notifier)
        .onNewMessage(
          conversationId: conversationId,
          content: decryptedContent,
          timestamp: timestamp,
          senderUsername: senderUsername,
        );
  }

  void _handleTyping(Map<String, dynamic> json, String myUserId) {
    final conversationId = json['conversation_id'] as String;
    final channelId = json['channel_id'] as String?;
    final fromUserId =
        (json['from_user_id'] as String?) ?? (json['user_id'] as String?) ?? '';
    final fromUsername = json['from_username'] as String? ?? 'Someone';

    // Don't show own typing indicator
    if (fromUserId == myUserId) return;

    final typingKey = '$conversationId:${channelId ?? ''}';
    final updatedTyping = Map<String, Map<String, DateTime>>.from(
      state.typingUsers,
    );
    final conversationTyping = Map<String, DateTime>.from(
      updatedTyping[typingKey] ?? {},
    );
    conversationTyping[fromUsername] = DateTime.now();
    updatedTyping[typingKey] = conversationTyping;

    state = state.copyWith(typingUsers: updatedTyping);
  }

  void _handleReaction(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final reaction = Reaction.fromJson(json);
    ref.read(chatProvider.notifier).addReaction(conversationId, reaction);
  }

  void _handleRemoveReaction(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    final userId = json['user_id'] as String;
    final emoji = json['emoji'] as String;
    ref
        .read(chatProvider.notifier)
        .removeReaction(conversationId, messageId, userId, emoji);
  }

  void _handleDelivered(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    ref
        .read(chatProvider.notifier)
        .updateMessageStatus(
          conversationId,
          messageId,
          MessageStatus.delivered,
        );
  }

  void _handleReadReceipt(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    ref.read(chatProvider.notifier).markConversationRead(conversationId);
  }

  void _handleMessageDeleted(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    ref.read(chatProvider.notifier).deleteMessage(conversationId, messageId);
  }

  void _handleMessageEdited(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    final newContent = json['content'] as String;
    final editedAt = json['edited_at'] as String?;
    ref
        .read(chatProvider.notifier)
        .editMessage(conversationId, messageId, newContent, editedAt: editedAt);
    // Update conversation list preview in case this was the last message.
    ref
        .read(conversationsProvider.notifier)
        .onMessageEdited(
          conversationId: conversationId,
          newContent: newContent,
        );
  }

  void _handleEncryptionToggled(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final isEncrypted = json['is_encrypted'] as bool;
    ref
        .read(conversationsProvider.notifier)
        .updateEncryption(conversationId, isEncrypted);
    ref
        .read(chatProvider.notifier)
        .addSystemEvent(
          conversationId,
          isEncrypted ? 'encryption_enabled' : 'encryption_disabled',
        );
  }

  void _handleMention(Map<String, dynamic> json, String myUserId) {
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';
    final content = json['content'] as String? ?? '';

    // Only show notification if someone else mentions us
    final fromUserId = json['from_user_id'] as String? ?? '';
    if (fromUserId == myUserId) return;

    SoundService().playMessageReceived();
    NotificationService().showMessageNotification(
      senderUsername: fromUsername,
      body: content.length > 100 ? '${content.substring(0, 100)}...' : content,
    );

    // Bump unread count for the conversation
    if (conversationId.isNotEmpty) {
      ref
          .read(conversationsProvider.notifier)
          .onNewMessage(
            conversationId: conversationId,
            content: content,
            timestamp: DateTime.now().toIso8601String(),
            senderUsername: fromUsername,
          );
    }
  }

  void _handlePresence(Map<String, dynamic> json) {
    final userId = json['user_id'] as String? ?? '';
    final status = json['status'] as String? ?? '';
    if (userId.isEmpty) return;

    final updated = Set<String>.from(state.onlineUsers);
    if (status == 'online') {
      updated.add(userId);
    } else {
      updated.remove(userId);
    }
    state = state.copyWith(onlineUsers: updated);
  }

  void _handlePresenceList(Map<String, dynamic> json) {
    final users = (json['users'] as List?)?.cast<String>() ?? [];
    state = state.copyWith(onlineUsers: users.toSet());
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
