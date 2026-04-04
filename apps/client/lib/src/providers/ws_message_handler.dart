import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Mixin that contains all WebSocket message handling logic.
///
/// Extracted from [WebSocketNotifier] to keep the coordinator focused on
/// connection lifecycle and message sending, while this mixin owns the
/// event dispatch and business logic for each incoming server message type.
mixin WsMessageHandler on StateNotifier<WebSocketState> {
  Ref get ref;
  StreamController<Map<String, dynamic>> get voiceSignalController;
  Set<String> get retriedPeers;

  /// Dispatch an incoming server message to the appropriate handler.
  void handleServerMessage(Map<String, dynamic> json, String myUserId) {
    final type = json['type'] as String;

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
    voiceSignalController.add(json);
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
        if (!retriedPeers.contains(fromUserId)) {
          // First failure for this peer this connection -- invalidate session
          // and retry once.
          retriedPeers.add(fromUserId);
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
}
