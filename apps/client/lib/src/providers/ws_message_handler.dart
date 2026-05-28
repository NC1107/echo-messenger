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
import '../services/group_rotation_election.dart';
import '../screens/settings/notification_section.dart'
    show shouldSuppressNotification;
import '../services/notification_service.dart';
import '../services/sound_service.dart';
import '../utils/crypto_utils.dart';
import '../utils/debug_log.dart';
import '../utils/mention_detection.dart';
import '../utils/presence.dart';
import '../utils/uuid_bytes.dart';
import 'auth_provider.dart';
import 'canvas_provider.dart';
import 'channels_provider.dart';
import 'chat_provider.dart';
import 'conversations_provider.dart';
import 'crypto_provider.dart';
import 'encrypted_preview_provider.dart';
import 'server_url_provider.dart';

part 'ws_handlers/message_handlers.dart';
part 'ws_handlers/typing_reaction_handlers.dart';
part 'ws_handlers/presence_handlers.dart';
part 'ws_handlers/voice_handlers.dart';
part 'ws_handlers/crypto_handlers.dart';

/// Placeholder content rendered when an inbound GRP2 group message fails
/// sender signature verification (or the sender's verify key cannot be
/// fetched). Distinct from "[Could not decrypt…]" because this is a
/// security signal, not a key-out-of-sync transient.
const _kCouldNotVerifySender = '[Could not verify sender]';

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

  /// (#503) userId -> last seen; only populated for peers observed going
  /// offline this session, header falls back to "offline" otherwise.
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

  /// Return a [UserPresence] snapshot — the structured pair that
  /// downstream widgets actually want. Lets callers replace the inline
  /// `onlineUsers.contains(...) + presenceStatuses[...] ?? 'online'`
  /// pattern with a single method call.
  UserPresence presenceFor(String userId) {
    final isOnline = onlineUsers.contains(userId);
    final status = isOnline
        ? (presenceStatuses[userId] ?? 'online')
        : 'offline';
    return UserPresence(status: status, isOnline: isOnline);
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
mixin WsMessageHandler on Notifier<WebSocketState> {
  // `ref` is provided by the parent Notifier class (codegen migration #770);
  // the redundant getter declaration the legacy StateNotifier mixin needed
  // is no longer required.
  StreamController<Map<String, dynamic>> get voiceSignalController;

  /// Broadcast of `device_revoked` events for the current user. UI surfaces
  /// (e.g. the Devices settings screen) listen here so they can refresh their
  /// lists when another device is revoked.
  StreamController<Map<String, dynamic>> get deviceRevokedController;

  /// (#830) Pre-crypto-init envelope queue; each entry binds an owner-userId
  /// so drain after logout can't leak user A's ciphertext into user B.
  final List<_PendingDecryptEntry> _pendingDecryptQueue = [];

  /// Length of the pending decrypt queue. Exposed for tests asserting that
  /// the session-cleanup paths actually empty the queue.
  int get pendingDecryptQueueLength => _pendingDecryptQueue.length;

  /// Suppression window after the WS first connects in a session. Backfill
  /// messages from every group land via `new_message` during this window
  /// and would otherwise fire a notification toast + chime per message
  /// (testers reported this as "spam on login"). Reset by
  /// [openInitialSyncWindow] on every fresh connect.
  bool _isInInitialSyncWindow = false;
  Timer? _initialSyncWindowTimer;

  /// Mark the start of a fresh WS session — any inbound `new_message`
  /// events for the next [duration] are treated as backfill and skip
  /// the notification fan-out. Calls after the first reset the timer
  /// so a quick reconnect doesn't double-fire notifications either.
  void openInitialSyncWindow({Duration duration = const Duration(seconds: 5)}) {
    _isInInitialSyncWindow = true;
    _initialSyncWindowTimer?.cancel();
    _initialSyncWindowTimer = Timer(duration, () {
      _isInInitialSyncWindow = false;
    });
  }

  /// Enqueue an envelope that arrived before crypto finished initialising.
  /// Records the currently-authenticated user ID alongside the payload so the
  /// drain step can refuse cross-account leakage (#830 finding 4).
  void _enqueuePendingDecrypt(Map<String, dynamic> json, String myUserId) {
    _pendingDecryptQueue.add(
      _PendingDecryptEntry(ownerUserId: myUserId, json: json),
    );
  }

  /// Library-private state accessor so part-file extensions avoid the
  /// invalid_use_of_protected_member lint on `state`.
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

  /// Clear pending decrypt queue without draining.
  /// Called when auth session changes (logout, session_replaced, device_revoked)
  /// to prevent cross-account message leakage (audit 2026-05-12, finding #4).
  void clearPendingDecryptQueue() {
    _pendingDecryptQueue.clear();
  }

  /// Decrypt queued messages that arrived before crypto init completed.
  ///
  /// Defensively drops any queue entries whose owning user ID does not match
  /// [myUserId]. If user A logs out mid-decrypt and user B logs in on the
  /// same process before the queue was cleared, those stale ciphertext
  /// envelopes must never be delivered into user B's state (#830 finding 4).
  void drainPendingDecryptQueue(String myUserId) {
    if (_pendingDecryptQueue.isEmpty) return;
    final crypto = ref.read(cryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    crypto.setToken(token);

    final queue = List<_PendingDecryptEntry>.from(_pendingDecryptQueue);
    _pendingDecryptQueue.clear();

    for (final entry in queue) {
      if (entry.ownerUserId != myUserId) {
        // Defence in depth: drop cross-account envelopes silently.
        DebugLogService.instance.log(
          LogLevel.warning,
          'WebSocket',
          'Dropped pending decrypt entry owned by '
              '${entry.ownerUserId} (current user $myUserId)',
        );
        continue;
      }
      final json = entry.json;
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
    // #26: true when the message was already in the Hive cache, meaning it was
    // seen in a prior session. Suppresses the unread-count bump and notification
    // so that replayed offline messages don't spam the user on re-login.
    bool alreadySeen = false,
  }) async {
    // Phase 2D: GRP2 receive needs message_id to verify the sender
    // signature against the same UUID the sender bound. Pull from the
    // raw frame (the server emits it on every relayed message).
    final messageIdForVerify = json['message_id'] as String?;
    final (decryptedContent, wasEncrypted) = await _decryptContent(
      crypto,
      rawContent,
      fromUserId,
      conversationId,
      fromDeviceId,
      messageId: messageIdForVerify,
    );

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

    final isMention = _detectMention(fromUserId, myUserId, decryptedContent);

    // When the user opts out of encrypted previews, replace plaintext with
    // the bracketed sentinel before it reaches the sidebar or notifications.
    // The actual chat bubble always shows the full decrypted text regardless.
    final showPreviews = wasEncrypted
        ? ref.read(showEncryptedPreviewsProvider)
        : true;
    final previewContent = showPreviews ? decryptedContent : '[Encrypted]';

    // Update conversations list with decrypted preview.
    // #26: don't bump unread for messages that were already cached (replayed).
    ref
        .read(conversationsProvider.notifier)
        .onNewMessage(
          conversationId: conversationId,
          content: previewContent,
          timestamp: timestamp,
          senderUsername: senderUsername,
          isMention: isMention,
          incrementUnread: !alreadySeen,
        );

    // #26: don't re-notify for messages the user already saw.
    if (fromUserId != myUserId && !alreadySeen) {
      _notifyIfAllowed(
        conversationId,
        senderUsername,
        previewContent,
        isMention: isMention,
      );
    }
  }

  /// Decrypt message content based on type (group-encrypted, DM-encrypted, or plaintext).
  /// Returns (decryptedContent, wasEncrypted).
  Future<(String, bool)> _decryptContent(
    CryptoService crypto,
    String rawContent,
    String fromUserId,
    String conversationId,
    int? fromDeviceId, {
    String? messageId,
  }) async {
    final isGrp1 = rawContent.startsWith(groupEncryptedPrefix);
    final isGrp2 = rawContent.startsWith(groupEncryptedPrefixV2);
    final isGroupEncrypted = isGrp1 || isGrp2;

    // Check if this is a group conversation
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
      return (
        await _decryptGroupMessage(
          crypto,
          rawContent,
          conversationId,
          fromUserId: fromUserId,
          fromDeviceId: fromDeviceId,
          messageId: messageId,
        ),
        true,
      );
    } else if (!wasEncrypted) {
      return (rawContent, false);
    } else {
      return (
        await _decryptDmMessage(
          crypto,
          fromUserId,
          rawContent,
          conversationId,
          fromDeviceId,
        ),
        true,
      );
    }
  }

  /// Decrypt a group-encrypted message using the group key.
  ///
  /// Dispatches by wire prefix:
  ///   - `GRP2:` → fetch sender's per-device Ed25519 signing pubkey,
  ///     verify signature over (version, conv_id, msg_id, nonce, ct,
  ///     tag), then decrypt. Audit OQ-12.
  ///   - `GRP1:` → legacy path (no signature). Refused when the cached
  ///     envelope's `min_wire_version` pins the conversation to GRP2,
  ///     so a hostile sender / server can't downgrade by framing
  ///     content as GRP1. Audit OQ-11.
  Future<String> _decryptGroupMessage(
    CryptoService crypto,
    String rawContent,
    String conversationId, {
    required String fromUserId,
    required int? fromDeviceId,
    required String? messageId,
  }) async {
    try {
      final groupCrypto = ref.read(groupCryptoServiceProvider);
      final token = ref.read(authProvider).token ?? '';
      groupCrypto.setToken(token);
      final keyResult = await groupCrypto.getGroupKey(conversationId);
      if (keyResult == null) {
        return '[Could not decrypt - waiting for group key]';
      }
      final (_, keyBase64) = keyResult;
      final minWireVersion =
          groupCrypto.cachedMinWireVersion(conversationId) ?? 1;

      final isGrp2 = rawContent.startsWith(groupEncryptedPrefixV2);
      if (isGrp2) {
        if (messageId == null || messageId.isEmpty) {
          debugLog(
            'GRP2 wire missing message_id (conv=$conversationId, '
                'from=$fromUserId)',
            'WebSocket',
          );
          return _kCouldNotVerifySender;
        }
        final senderVerifyKey = await crypto.getSenderVerifyKeyForDevice(
          fromUserId,
          fromDeviceId,
        );
        if (senderVerifyKey == null) {
          debugLog(
            'GRP2 sender verify key not found for '
                '$fromUserId:$fromDeviceId',
            'WebSocket',
          );
          return _kCouldNotVerifySender;
        }
        try {
          return await GroupCryptoService.verifyAndDecryptGroupMessageV2(
            ciphertextWithPrefix: rawContent,
            keyBase64: keyBase64,
            expectedConversationIdBytes: uuidStringToBytes(conversationId),
            expectedMessageIdBytes: uuidStringToBytes(messageId),
            senderVerifyKey: senderVerifyKey,
          );
        } on GroupSenderSignatureException catch (e) {
          // Distinct placeholder lets chat UI stripe in a danger color.
          debugLog(
            'GRP2 signature failed for $conversationId msg=$messageId: $e',
            'WebSocket',
          );
          return _kCouldNotVerifySender;
        }
      }

      // GRP1 refused when envelope is pinned to GRP2 (downgrade attack).
      if (minWireVersion >= 2) {
        debugLog(
          'GRP1 wire refused at min_wire_version=$minWireVersion '
              '(conv=$conversationId)',
          'WebSocket',
        );
        return _kCouldNotVerifySender;
      }
      return await GroupCryptoService.decryptGroupMessage(
        rawContent,
        keyBase64,
      );
    } catch (e) {
      debugLog('Group decrypt failed for $conversationId: $e', 'WebSocket');
      return '[Could not decrypt group message]';
    }
  }

  /// Decrypt a DM message using Signal Protocol.
  Future<String> _decryptDmMessage(
    CryptoService crypto,
    String fromUserId,
    String rawContent,
    String conversationId,
    int? fromDeviceId,
  ) async {
    try {
      return await crypto.decryptMessage(
        fromUserId,
        rawContent,
        fromDeviceId: fromDeviceId,
      );
    } catch (e) {
      debugLog(
        'Decryption failed for message in $conversationId '
            'from $fromUserId: $e',
        'WebSocket',
      );
      return '[Could not decrypt - encryption keys may be out of sync]';
    }
  }

  /// Check if a message contains a mention of the current user.
  bool _detectMention(
    String fromUserId,
    String myUserId,
    String decryptedContent,
  ) {
    // Run over decrypted plaintext; skip self so users don't badge themselves.
    if (fromUserId == myUserId) return false;
    return containsMention(decryptedContent, ref.read(authProvider).username);
  }

  /// Show a notification + play sound if the conversation is not muted and
  /// the user isn't currently in DND or quiet hours.
  ///
  /// Mentions play a louder ping ([SoundService.playMention]) so the user
  /// can hear the difference between a passing group message and one that
  /// names them.
  void _notifyIfAllowed(
    String conversationId,
    String senderUsername,
    String displayContent, {
    bool isMention = false,
  }) {
    // Suppress notification fan-out during the initial WS sync window.
    // Without this, every backfilled message from every group lands as a
    // separate toast + chime on login — testers consistently reported
    // this as "spam on first launch" (2026-05-27 feedback).
    if (_isInInitialSyncWindow) return;

    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    final isMuted = conv?.isMuted ?? false;
    if (isMuted) return;

    // Gate sound+toast on DND/quiet-hours; pre-check keeps them aligned.
    shouldSuppressNotification().then((suppress) {
      if (suppress) return;
      if (isMention) {
        SoundService().playMention().ignore();
      } else {
        SoundService().playMessageReceived().ignore();
      }
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
    });
  }

  void _handleCanvasEvent(Map<String, dynamic> json) {
    ref.read(canvasProvider.notifier).handleCanvasEvent(json);
  }
}

/// Single entry in the pending-decrypt queue. Binds the envelope to the user
/// ID that was authenticated when it was enqueued so a drain after a logout
/// can refuse to deliver into the wrong account (#830 finding 4).
class _PendingDecryptEntry {
  final String ownerUserId;
  final Map<String, dynamic> json;

  const _PendingDecryptEntry({required this.ownerUserId, required this.json});
}
