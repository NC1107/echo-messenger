import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../services/crypto_service.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'conversations_provider.dart';
import 'crypto_provider.dart';

/// State that tracks both connection status and typing indicators.
class WebSocketState {
  final bool isConnected;

  /// Map of conversationId -> set of usernames currently typing.
  final Map<String, Map<String, DateTime>> typingUsers;

  const WebSocketState({
    this.isConnected = false,
    this.typingUsers = const {},
  });

  WebSocketState copyWith({
    bool? isConnected,
    Map<String, Map<String, DateTime>>? typingUsers,
  }) {
    return WebSocketState(
      isConnected: isConnected ?? this.isConnected,
      typingUsers: typingUsers ?? this.typingUsers,
    );
  }

  /// Get list of usernames typing in a given conversation.
  List<String> typingIn(String conversationId) {
    final users = typingUsers[conversationId];
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

  /// Throttle: track last typing event sent per conversation.
  final Map<String, DateTime> _lastTypingSent = {};

  WebSocketNotifier(this.ref) : super(const WebSocketState()) {
    // Periodically clean up stale typing indicators
    _typingCleanupTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _cleanupTyping(),
    );
  }

  void connect() {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    disconnect();

    final uri = Uri.parse('ws://localhost:8080/ws?token=$token');
    _channel = WebSocketChannel.connect(uri);
    state = state.copyWith(isConnected: true);

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

  /// Send an encrypted message to a peer.
  Future<void> sendMessage(String toUserId, String content,
      {String? conversationId}) async {
    final cryptoState = ref.read(cryptoProvider);
    String payload = content;

    if (cryptoState.isInitialized) {
      try {
        final crypto = ref.read(cryptoServiceProvider);
        final token = ref.read(authProvider).token ?? '';
        crypto.setToken(token);
        payload = await crypto.encryptMessage(toUserId, content);
      } catch (_) {
        // Fall back to plaintext if encryption fails.
      }
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

  /// Send a message to a group conversation.
  Future<void> sendGroupMessage(String conversationId, String content) async {
    _channel?.sink.add(jsonEncode({
      'type': 'send_message',
      'conversation_id': conversationId,
      'content': content,
    }));
  }

  /// Send a typing indicator (throttled to max 1 per 3 seconds per conversation).
  void sendTyping(String conversationId) {
    final now = DateTime.now();
    final lastSent = _lastTypingSent[conversationId];
    if (lastSent != null && now.difference(lastSent).inSeconds < 3) {
      return;
    }
    _lastTypingSent[conversationId] = now;

    _channel?.sink.add(jsonEncode({
      'type': 'typing',
      'conversation_id': conversationId,
    }));
  }

  /// Send a reaction.
  void sendReaction(String conversationId, String messageId, String emoji) {
    _channel?.sink.add(jsonEncode({
      'type': 'reaction',
      'conversation_id': conversationId,
      'message_id': messageId,
      'emoji': emoji,
    }));
  }

  /// Remove a reaction.
  void removeReaction(String conversationId, String messageId, String emoji) {
    _channel?.sink.add(jsonEncode({
      'type': 'remove_reaction',
      'conversation_id': conversationId,
      'message_id': messageId,
      'emoji': emoji,
    }));
  }

  /// Send a read receipt via WebSocket.
  void sendReadReceipt(String conversationId) {
    _channel?.sink.add(jsonEncode({
      'type': 'read_receipt',
      'conversation_id': conversationId,
    }));
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
        _handleReaction(json);
      case 'remove_reaction':
        _handleRemoveReaction(json);
      case 'delivered':
        _handleDelivered(json);
      case 'error':
        break;
    }
  }

  void _handleMessageSent(Map<String, dynamic> json) {
    final messageId = json['message_id'] as String;
    final conversationId = json['conversation_id'] as String;
    final timestamp = json['timestamp'] as String;
    ref.read(chatProvider.notifier).confirmSent(
          messageId,
          conversationId,
          timestamp,
        );
    // Update status to sent
    ref.read(chatProvider.notifier).updateMessageStatus(
          conversationId,
          messageId,
          MessageStatus.sent,
        );
  }

  void _handleNewMessage(Map<String, dynamic> json, String myUserId) {
    final rawContent = json['content'] as String;
    final fromUserId = json['from_user_id'] as String;
    final cryptoState = ref.read(cryptoProvider);

    if (cryptoState.isInitialized) {
      final crypto = ref.read(cryptoServiceProvider);
      final token = ref.read(authProvider).token ?? '';
      crypto.setToken(token);
      _decryptAndDeliver(crypto, json, rawContent, fromUserId, myUserId);
    } else {
      final msg = ChatMessage.fromServerJson(json, myUserId);
      ref.read(chatProvider.notifier).addMessage(msg);
    }

    // Update conversations list
    ref.read(conversationsProvider.notifier).onNewMessage(
          conversationId: json['conversation_id'] as String,
          content: rawContent,
          timestamp: json['timestamp'] as String,
          senderUsername: json['from_username'] as String,
        );
  }

  Future<void> _decryptAndDeliver(
    CryptoService crypto,
    Map<String, dynamic> json,
    String rawContent,
    String fromUserId,
    String myUserId,
  ) async {
    String decryptedContent;
    try {
      decryptedContent = await crypto.decryptMessage(fromUserId, rawContent);
    } catch (_) {
      decryptedContent = rawContent;
    }

    final decryptedJson = Map<String, dynamic>.from(json);
    decryptedJson['content'] = decryptedContent;
    final msg = ChatMessage.fromServerJson(decryptedJson, myUserId);
    ref.read(chatProvider.notifier).addMessage(msg);
  }

  void _handleTyping(Map<String, dynamic> json, String myUserId) {
    final conversationId = json['conversation_id'] as String;
    final fromUserId = json['from_user_id'] as String? ?? '';
    final fromUsername = json['from_username'] as String? ?? 'Someone';

    // Don't show own typing indicator
    if (fromUserId == myUserId) return;

    final updatedTyping =
        Map<String, Map<String, DateTime>>.from(state.typingUsers);
    final conversationTyping =
        Map<String, DateTime>.from(updatedTyping[conversationId] ?? {});
    conversationTyping[fromUsername] = DateTime.now();
    updatedTyping[conversationId] = conversationTyping;

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
    ref.read(chatProvider.notifier).updateMessageStatus(
          conversationId,
          messageId,
          MessageStatus.delivered,
        );
  }

  /// Remove stale typing indicators (older than 5 seconds).
  void _cleanupTyping() {
    final now = DateTime.now();
    var changed = false;
    final updatedTyping =
        Map<String, Map<String, DateTime>>.from(state.typingUsers);

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
    disconnect();
    super.dispose();
  }
}

final websocketProvider =
    StateNotifierProvider<WebSocketNotifier, WebSocketState>((ref) {
  return WebSocketNotifier(ref);
});
