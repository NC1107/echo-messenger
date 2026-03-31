import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import '../services/crypto_service.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'crypto_provider.dart';

class WebSocketNotifier extends StateNotifier<bool> {
  final Ref ref;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  WebSocketNotifier(this.ref) : super(false);

  void connect() {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    disconnect();

    final uri = Uri.parse('ws://localhost:8080/ws?token=$token');
    _channel = WebSocketChannel.connect(uri);
    state = true;

    _subscription = _channel!.stream.listen(
      (data) => _onMessage(data as String),
      onDone: () {
        state = false;
        Future.delayed(const Duration(seconds: 3), () {
          if (ref.read(authProvider).isLoggedIn) connect();
        });
      },
      onError: (_) => state = false,
    );
  }

  void disconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    state = false;
  }

  /// Send an encrypted message to a peer.
  Future<void> sendMessage(String toUserId, String content) async {
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
        // In production this should never silently degrade.
      }
    }

    _channel?.sink.add(
      jsonEncode({
        'type': 'send_message',
        'to_user_id': toUserId,
        'content': payload,
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
        ref
            .read(chatProvider.notifier)
            .confirmSent(
              json['message_id'] as String,
              json['conversation_id'] as String,
              json['timestamp'] as String,
            );
      case 'error':
        break;
    }
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
      // No crypto initialized, deliver as-is
      final msg = ChatMessage.fromServerJson(json, myUserId);
      ref.read(chatProvider.notifier).addMessage(msg);
    }
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
      // If decryption fails, show the raw content (might be plaintext
      // from a client that hasn't set up encryption yet).
      decryptedContent = rawContent;
    }

    final decryptedJson = Map<String, dynamic>.from(json);
    decryptedJson['content'] = decryptedContent;
    final msg = ChatMessage.fromServerJson(decryptedJson, myUserId);
    ref.read(chatProvider.notifier).addMessage(msg);
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

final websocketProvider = StateNotifierProvider<WebSocketNotifier, bool>((ref) {
  return WebSocketNotifier(ref);
});
