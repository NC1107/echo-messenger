import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../services/crypto_service.dart';
import '../services/debug_log_service.dart';
import '../services/message_cache.dart';
import '../services/group_crypto_service.dart';
import '../services/notification_service.dart';
import '../services/sound_service.dart';
import '../utils/crypto_utils.dart';
import '../utils/debug_log.dart';
import 'auth_provider.dart';
import 'canvas_provider.dart';
import 'channels_provider.dart';
import 'chat_provider.dart';
import 'conversations_provider.dart';
import 'crypto_provider.dart';

/// State that tracks both connection status and typing indicators.
class WebSocketState {
  final bool isConnected;
  final int reconnectAttempts;

  /// Map of conversationId -> set of usernames currently typing.
  final Map<String, Map<String, DateTime>> typingUsers;

  /// Set of user IDs currently known to be online (from presence events).
  final Set<String> onlineUsers;

  /// Map of userId -> presence_status ("online", "away", "dnd", "invisible").
  /// Updated from presence events that include the presence_status field.
  final Map<String, String> presenceStatuses;

  /// Map of userId -> last seen timestamp. Populated from offline presence
  /// events that include `last_seen_at`. Only peers we observe transition
  /// online → offline during this session have an entry; truly long-offline
  /// peers stay null and the header falls back to "offline" (#503).
  final Map<String, DateTime> lastSeenAt;

  /// True when the server sent a `session_replaced` event, meaning another
  /// device/tab took over this user's WebSocket session.
  final bool wasReplaced;

  const WebSocketState({
    this.isConnected = false,
    this.reconnectAttempts = 0,
    this.typingUsers = const {},
    this.onlineUsers = const {},
    this.presenceStatuses = const {},
    this.lastSeenAt = const {},
    this.wasReplaced = false,
  });

  WebSocketState copyWith({
    bool? isConnected,
    int? reconnectAttempts,
    Map<String, Map<String, DateTime>>? typingUsers,
    Set<String>? onlineUsers,
    Map<String, String>? presenceStatuses,
    Map<String, DateTime>? lastSeenAt,
    bool? wasReplaced,
  }) {
    return WebSocketState(
      isConnected: isConnected ?? this.isConnected,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      typingUsers: typingUsers ?? this.typingUsers,
      onlineUsers: onlineUsers ?? this.onlineUsers,
      presenceStatuses: presenceStatuses ?? this.presenceStatuses,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      wasReplaced: wasReplaced ?? this.wasReplaced,
    );
  }

  /// Check if a specific user is online.
  bool isUserOnline(String userId) => onlineUsers.contains(userId);

  /// Return the last seen timestamp for an offline user, or null if we
  /// haven't observed them go offline this session.
  DateTime? lastSeenFor(String userId) => lastSeenAt[userId];

  /// Return the presence status for a given user ID.
  /// Returns "offline" when the user is not in the online set.
  String presenceStatusFor(String userId) {
    if (!onlineUsers.contains(userId)) return 'offline';
    return presenceStatuses[userId] ?? 'online';
  }

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

  /// Broadcast of `device_revoked` events for the current user. UI surfaces
  /// (e.g. the Devices settings screen) listen here so they can refresh their
  /// lists when another device is revoked.
  StreamController<Map<String, dynamic>> get deviceRevokedController;

  /// Messages received before crypto was initialized.
  /// Drained by [drainPendingDecryptQueue] once crypto is ready.
  final List<Map<String, dynamic>> _pendingDecryptQueue = [];

  /// Decrypt queued messages that arrived before crypto init completed.
  void drainPendingDecryptQueue(String myUserId) {
    if (_pendingDecryptQueue.isEmpty) return;
    final crypto = ref.read(cryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    crypto.setToken(token);

    final queue = List<Map<String, dynamic>>.from(_pendingDecryptQueue);
    _pendingDecryptQueue.clear();

    for (final json in queue) {
      final rawContent = (json['content'] ?? '').toString();
      final fromUserId = json['from_user_id'] as String? ?? '';
      final conversationId = json['conversation_id'] as String? ?? '';
      final timestamp = json['timestamp'] as String? ?? '';
      final senderUsername = json['from_username'] as String? ?? '';
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
    }
  }

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
      case 'message_expired':
        _handleMessageExpired(json);
      case 'message_pinned':
        _handleMessagePinned(json);
      case 'message_unpinned':
        _handleMessageUnpinned(json);
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
      case 'group_key_rotated':
        _handleGroupKeyRotated(json);
      case 'self_message':
        _handleSelfMessage(json, myUserId);
      case 'session_replaced':
        _handleSessionReplaced(json);
      case 'device_revoked':
        _handleDeviceRevoked(json);
      case 'heartbeat':
        break; // Server keepalive; _onMessage already updated _lastMessageTime.
      case 'error':
        break;
      case 'voice_signal':
        _handleVoiceSignal(json);
      case 'key_reset':
        _handleKeyReset(json);
      case 'call_started':
        _handleCallStarted(json);
      case 'canvas_event':
        _handleCanvasEvent(json);
      default:
        DebugLogService.instance.log(
          LogLevel.warning,
          'WebSocket',
          'Unknown message type: $type',
        );
    }
  }

  void _handleVoiceSignal(Map<String, dynamic> json) {
    voiceSignalController.add(json);
  }

  void _handleKeyReset(Map<String, dynamic> json) {
    final fromUserId = json['from_user_id'] as String? ?? '';
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';

    // Invalidate the local session so the next message re-establishes X3DH
    ref.read(cryptoServiceProvider).invalidateSessionKey(fromUserId);

    ref
        .read(chatProvider.notifier)
        .addSystemEvent(
          conversationId,
          '$fromUsername reset their encryption keys',
        );
  }

  void _handleCallStarted(Map<String, dynamic> json) {
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';

    ref
        .read(chatProvider.notifier)
        .addSystemEvent(conversationId, '$fromUsername started a voice call');

    // Show notification
    final myUserId = ref.read(authProvider).userId ?? '';
    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    NotificationService().showMessageNotification(
      senderUsername: fromUsername,
      body: 'Started a voice call',
      conversationId: conversationId,
      conversationName: conv?.displayName(myUserId),
      isMuted: conv?.isMuted ?? false,
    );
  }

  void _handleSessionReplaced(Map<String, dynamic> json) {
    final reason = json['reason'] as String? ?? 'Signed in on another device';
    DebugLogService.instance.log(
      LogLevel.warning,
      'WebSocket',
      'Session replaced by another connection: $reason',
    );
    state = state.copyWith(wasReplaced: true, isConnected: false);
  }

  void _handleDeviceRevoked(Map<String, dynamic> json) {
    // Use `num?` + toInt() so dart2js (web) doesn't blow up when the JSON
    // number is decoded as a double rather than an int.
    final revokedDeviceId = (json['device_id'] as num?)?.toInt();
    final myDeviceId = ref.read(cryptoServiceProvider).isInitialized
        ? ref.read(cryptoServiceProvider).deviceId
        : null;

    // Always broadcast so interested UIs (Devices settings) can refresh.
    deviceRevokedController.add(json);

    if (revokedDeviceId != null &&
        myDeviceId != null &&
        revokedDeviceId == myDeviceId) {
      // This device was revoked -- force logout.
      DebugLogService.instance.log(
        LogLevel.warning,
        'WebSocket',
        'Current device ($revokedDeviceId) was revoked; logging out.',
      );
      state = state.copyWith(isConnected: false);
      ref.read(authProvider.notifier).logout();
    }
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
    final expiresAtRaw = json['expires_at'];
    final expiresAt = expiresAtRaw is String
        ? DateTime.tryParse(expiresAtRaw)
        : null;
    ref
        .read(chatProvider.notifier)
        .confirmSent(
          messageId,
          conversationId,
          timestamp,
          channelId: channelId,
          expiresAt: expiresAt,
        );
    // Update status to sent
    ref
        .read(chatProvider.notifier)
        .updateMessageStatus(conversationId, messageId, MessageStatus.sent);

    // Update conversation list preview so the sender sees their own message
    // reflected immediately (e.g. attachment markers, text). Without this the
    // conversation preview stays stale until the next server fetch.
    final confirmed = ref
        .read(chatProvider)
        .messagesForConversation(conversationId)
        .where((m) => m.id == messageId)
        .firstOrNull;
    if (confirmed != null) {
      ref
          .read(conversationsProvider.notifier)
          .onNewMessage(
            conversationId: conversationId,
            content: confirmed.content,
            timestamp: timestamp,
            senderUsername: confirmed.fromUsername,
            incrementUnread: false,
          );
    }
  }

  void _handleNewMessage(Map<String, dynamic> json, String myUserId) {
    final rawContent = json['content'] as String;
    final fromUserId = json['from_user_id'] as String;
    final fromDeviceId = json['from_device_id'] as int?;
    final conversationId = json['conversation_id'] as String;
    final timestamp = json['timestamp'] as String;
    final senderUsername = json['from_username'] as String;
    final cryptoState = ref.read(cryptoProvider);

    // Check if this conversation is already known locally
    final isKnownConversation = ref
        .read(conversationsProvider)
        .conversations
        .any((c) => c.id == conversationId);

    // #557: server marks replay frames `undecryptable: true` when this device
    // has no per-device ciphertext row.  Render an explicit placeholder
    // instead of running decrypt over a foreign-device wire (which would
    // poison the local ratchet state and produce a generic "out of sync"
    // banner).  Skip the Hive cache write so a future fix-up can replace it.
    if (json['undecryptable'] == true) {
      final placeholder = ChatMessage.fromServerJson({
        ...json,
        'content': '[Encrypted for another device of this account]',
      }, myUserId).copyWith(isEncrypted: true);
      ref.read(chatProvider.notifier).addMessage(placeholder);
      ref
          .read(conversationsProvider.notifier)
          .onNewMessage(
            conversationId: conversationId,
            content: 'Encrypted message',
            timestamp: timestamp,
            senderUsername: senderUsername,
          );
      if (!isKnownConversation) {
        ref.read(conversationsProvider.notifier).loadConversations();
      }
      return;
    }

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
        fromDeviceId: fromDeviceId,
      );
    } else {
      // Crypto not ready yet — show a placeholder and queue for decryption.
      // The literal 'Securing message...' string is recognised by
      // chat_provider.dart's `_placeholderContents` so the decrypted
      // version replaces it in place when the queue drains (#430).
      final placeholder = ChatMessage.fromServerJson({
        ...json,
        'content': 'Securing message...',
      }, myUserId).copyWith(isEncrypted: true);
      ref.read(chatProvider.notifier).addMessage(placeholder);

      // Queue the raw JSON so it can be decrypted once crypto initializes
      _pendingDecryptQueue.add(json);

      ref
          .read(conversationsProvider.notifier)
          .onNewMessage(
            conversationId: conversationId,
            content: 'Encrypted message',
            timestamp: timestamp,
            senderUsername: senderUsername,
          );
    }

    // Only do a full HTTP reload if this is a new conversation we don't have
    // locally. For existing conversations, onNewMessage() already updates state.
    if (!isKnownConversation) {
      ref.read(conversationsProvider.notifier).loadConversations();
    }

    // When crypto is NOT initialized, notify with raw content (it's plaintext
    // in that case).  When crypto IS initialized, the notification fires AFTER
    // decryption inside _decryptAndDeliverWithPreview so users never see
    // encrypted ciphertext in their notifications.
    if (!cryptoState.isInitialized && fromUserId != myUserId) {
      _notifyIfAllowed(conversationId, senderUsername, rawContent);
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
    String senderUsername, {
    int? fromDeviceId,
  }) async {
    String decryptedContent;
    final isGroupEncrypted = rawContent.startsWith(groupEncryptedPrefix);

    // Check if this is a group conversation -- group messages that don't have
    // the GRP1: prefix are plaintext and should never be DM-decrypted.
    final conversation = ref
        .read(conversationsProvider)
        .conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final isGroupConversation = conversation?.isGroup ?? false;
    final wasEncrypted =
        isGroupEncrypted ||
        (!isGroupConversation && looksEncrypted(rawContent));

    if (isGroupEncrypted) {
      // Group-encrypted message -- decrypt with AES-256-GCM group key.
      try {
        final groupCrypto = ref.read(groupCryptoServiceProvider);
        final token = ref.read(authProvider).token ?? '';
        groupCrypto.setToken(token);
        final keyResult = await groupCrypto.getGroupKey(conversationId);
        if (keyResult != null) {
          final (_, keyBase64) = keyResult;
          decryptedContent = await GroupCryptoService.decryptGroupMessage(
            rawContent,
            keyBase64,
          );
        } else {
          decryptedContent = '[Could not decrypt - waiting for group key]';
        }
      } catch (e) {
        debugLog('Group decrypt failed for $conversationId: $e', 'WebSocket');
        decryptedContent = '[Could not decrypt group message]';
      }
    } else if (!wasEncrypted) {
      // Content does not look encrypted (e.g. plaintext group messages) --
      // deliver as-is without attempting decryption.
      decryptedContent = rawContent;
    } else {
      try {
        decryptedContent = await crypto.decryptMessage(
          fromUserId,
          rawContent,
          fromDeviceId: fromDeviceId,
        );
      } catch (e) {
        // Do NOT invalidate the session here. Invalidating and re-creating a
        // new X3DH outgoing session would put Alice and Bob out of sync,
        // permanently breaking all future messages in the conversation.
        // decryptMessage() already handles the legitimate peer-key-reset case
        // internally by detecting the X3DH magic prefix.
        debugLog(
          'Decryption failed for message in $conversationId '
              'from $fromUserId: $e',
          'WebSocket',
        );
        decryptedContent =
            '[Could not decrypt - encryption keys may be out of sync]';
      }
    }

    final decryptedJson = Map<String, dynamic>.from(json);
    decryptedJson['content'] = decryptedContent;
    var msg = ChatMessage.fromServerJson(decryptedJson, myUserId);
    if (wasEncrypted) {
      msg = msg.copyWith(isEncrypted: true);
    }
    ref.read(chatProvider.notifier).addMessage(msg);

    // Cache the decrypted message to Hive immediately so that historical
    // message loads can retrieve it without re-decryption (Double Ratchet
    // keys are consumed once and cannot be re-derived).
    if (!msg.id.startsWith('pending_')) {
      MessageCache.cacheMessages(conversationId, [msg]);
    }

    // Update conversations list with decrypted preview
    ref
        .read(conversationsProvider.notifier)
        .onNewMessage(
          conversationId: conversationId,
          content: decryptedContent,
          timestamp: timestamp,
          senderUsername: senderUsername,
        );

    // Notify with decrypted content so users never see ciphertext.
    if (fromUserId != myUserId) {
      _notifyIfAllowed(conversationId, senderUsername, decryptedContent);
    }
  }

  /// Handle a `self_message` event: an outgoing message sent from another
  /// device of the current user. Repackage as a new_message from self and
  /// reuse the standard decrypt-and-deliver pipeline.
  void _handleSelfMessage(Map<String, dynamic> json, String myUserId) {
    final rawContent = json['content'] as String? ?? '';
    final fromDeviceId = json['from_device_id'] as int?;
    final conversationId = json['conversation_id'] as String? ?? '';
    final timestamp = json['timestamp'] as String? ?? '';

    if (rawContent.isEmpty) return;

    // Repackage as a new_message so _decryptAndDeliverWithPreview handles it.
    final syntheticJson = <String, dynamic>{
      ...json,
      'from_user_id': myUserId,
      'from_username': 'Me',
    };

    final cryptoState = ref.read(cryptoProvider);
    if (!cryptoState.isInitialized) return;

    final crypto = ref.read(cryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    crypto.setToken(token);

    _decryptAndDeliverWithPreview(
      crypto,
      syntheticJson,
      rawContent,
      myUserId,
      myUserId,
      conversationId,
      timestamp,
      'Me',
      fromDeviceId: fromDeviceId,
    );
  }

  /// Show a notification + play sound if the conversation is not muted.
  void _notifyIfAllowed(
    String conversationId,
    String senderUsername,
    String displayContent,
  ) {
    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    final isMuted = conv?.isMuted ?? false;
    if (isMuted) return;

    SoundService().playMessageReceived();
    final body = displayContent.length > 100
        ? '${displayContent.substring(0, 100)}...'
        : displayContent;
    final myUserId = ref.read(authProvider).userId ?? '';
    NotificationService().showMessageNotification(
      senderUsername: senderUsername,
      body: body,
      conversationId: conversationId,
      conversationName: conv?.displayName(myUserId),
      isGroup: conv?.isGroup ?? false,
      isMuted: isMuted,
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

  void _handleMessageExpired(Map<String, dynamic> json) {
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

  void _handleMessagePinned(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    final pinnedById = json['pinned_by_id'] as String?;
    final pinnedAtRaw = json['pinned_at'] as String?;
    final pinnedAt = pinnedAtRaw != null
        ? DateTime.tryParse(pinnedAtRaw)
        : DateTime.now();
    ref
        .read(chatProvider.notifier)
        .updateMessagePin(conversationId, messageId, pinnedById, pinnedAt);
  }

  void _handleMessageUnpinned(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    ref
        .read(chatProvider.notifier)
        .updateMessagePin(conversationId, messageId, null, null);
  }

  void _handleMention(Map<String, dynamic> json, String myUserId) {
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';
    final content = json['content'] as String? ?? '';

    // Only show notification if someone else mentions us
    final fromUserId = json['from_user_id'] as String? ?? '';
    if (fromUserId == myUserId) return;

    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    final isMuted = conv?.isMuted ?? false;
    if (!isMuted) {
      SoundService().playMessageReceived();
    }
    NotificationService().showMessageNotification(
      senderUsername: '@$fromUsername',
      body: content.length > 100 ? '${content.substring(0, 100)}...' : content,
      conversationId: conversationId,
      conversationName: conv?.displayName(myUserId),
      isGroup: true, // Mentions are always in group contexts
      isMuted: isMuted,
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

  /// Handle group key rotation event -- invalidate cached key so the next
  /// encrypt/decrypt fetches the fresh version from the server.
  void _handleGroupKeyRotated(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String? ?? '';
    if (conversationId.isEmpty) return;

    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    groupCrypto.setToken(token);
    groupCrypto.invalidateCache(conversationId);

    // Pre-fetch the new key so subsequent messages decrypt immediately.
    groupCrypto.fetchGroupKey(conversationId);
  }

  void _handlePresence(Map<String, dynamic> json) {
    final userId = json['user_id'] as String? ?? '';
    final status = json['status'] as String? ?? '';
    // presence_status is the raw stored value (may differ from status when
    // broadcast_status is "offline" due to invisible setting).
    final presenceStatus = json['presence_status'] as String? ?? status;
    if (userId.isEmpty) return;

    final updatedOnline = Set<String>.from(state.onlineUsers);
    final updatedStatuses = Map<String, String>.from(state.presenceStatuses);
    final updatedLastSeen = Map<String, DateTime>.from(state.lastSeenAt);

    if (status == 'offline') {
      updatedOnline.remove(userId);
      updatedStatuses.remove(userId);
      // Stamp last_seen_at so the chat header can render "last seen <ago>"
      // for this peer (#503). Server provides RFC3339; fall back to now if
      // the field is absent (older server).
      final raw = json['last_seen_at'] as String?;
      final ts = raw != null ? DateTime.tryParse(raw) : null;
      updatedLastSeen[userId] = ts ?? DateTime.now().toUtc();
    } else {
      updatedOnline.add(userId);
      updatedStatuses[userId] = presenceStatus;
      // Don't clear lastSeenAt — preserve the previous value so a brief
      // online flash doesn't lose the historical timestamp on next offline.
    }
    state = state.copyWith(
      onlineUsers: updatedOnline,
      presenceStatuses: updatedStatuses,
      lastSeenAt: updatedLastSeen,
    );
  }

  void _handlePresenceList(Map<String, dynamic> json) {
    final users = (json['users'] as List?)?.cast<String>() ?? [];
    state = state.copyWith(onlineUsers: users.toSet());
  }

  void _handleCanvasEvent(Map<String, dynamic> json) {
    ref.read(canvasProvider.notifier).handleCanvasEvent(json);
  }
}
