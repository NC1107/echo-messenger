library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/conversation.dart';
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
import 'server_url_provider.dart';

part 'ws_handlers/message_handlers.dart';
part 'ws_handlers/typing_reaction_handlers.dart';
part 'ws_handlers/presence_handlers.dart';
part 'ws_handlers/voice_handlers.dart';
part 'ws_handlers/crypto_handlers.dart';

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
///
/// The handler implementations are split across feature-grouped part files
/// in `ws_handlers/` (message, typing/reaction, presence, voice, crypto).
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

  /// Library-private state accessors used by the part-file extensions.
  ///
  /// `StateNotifier.state` is `@protected`, so accessing it from an
  /// extension (even one defined in the same library) trips the analyzer's
  /// `invalid_use_of_protected_member` lint. Reading/writing through these
  /// instance members keeps the access within a subclass scope where the
  /// lint is satisfied, while the underscore prefix keeps them private to
  /// this library.
  WebSocketState get _state => state;
  set _state(WebSocketState value) => state = value;

  /// Clear all online-user state on disconnect so reconnect snapshot starts clean.
  ///
  /// Called by the connection lifecycle (onDone/onError) before scheduling a
  /// reconnect. The server sends a `presence_list` snapshot immediately on
  /// reconnect which repopulates the map with accurate data (#436).
  void clearOnlineUsers() {
    state = state.copyWith(onlineUsers: const {}, presenceStatuses: const {});
  }

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
      case 'group_key_rotation_requested':
        _handleGroupKeyRotationRequested(json);
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
      case 'identity_reset':
        _handleIdentityReset(json);
      case 'call_started':
        _handleCallStarted(json);
      case 'canvas_event':
        _handleCanvasEvent(json);
      case 'member_added':
        _handleMemberAdded(json);
      default:
        DebugLogService.instance.log(
          LogLevel.warning,
          'WebSocket',
          'Unknown message type: $type',
        );
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

  /// Shared decrypt-and-deliver pipeline used by both [_handleNewMessage]
  /// (in `message_handlers.dart`) and [drainPendingDecryptQueue]. Lives in
  /// the shell because it crosses both the live-message and queue-drain
  /// code paths.
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

  /// Show a notification + play sound if the conversation is not muted.
  /// Shared between the live and queued decrypt paths.
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

  void _handleCanvasEvent(Map<String, dynamic> json) {
    ref.read(canvasProvider.notifier).handleCanvasEvent(json);
  }
}
