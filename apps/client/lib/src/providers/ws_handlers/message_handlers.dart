part of '../ws_message_handler.dart';

/// Sentinel prefix used by system messages (#663).
const String _systemPrefix = '__system__:';

/// Parameters for plaintext and encrypted message delivery.
class _MessageDeliveryParams {
  _MessageDeliveryParams({
    required this.json,
    required this.rawContent,
    required this.myUserId,
    required this.conversationId,
    required this.timestamp,
    required this.senderUsername,
    required this.fromUserId,
    required this.alreadySeen,
  });
  final Map<String, dynamic> json;
  final String rawContent;
  final String myUserId;
  final String conversationId;
  final String timestamp;
  final String senderUsername;
  final String fromUserId;
  final bool alreadySeen;
}

extension MessageHandlersOn on WsMessageHandler {
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
    // Update conv preview so sender sees own message reflected immediately.
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

  /// Parse a `__system__:member_*` sentinel and emit an in-chat system event
  /// pill. Delegates to [ChatMessage.translateSystemSentinel] for consistent
  /// text generation. No preview update, no unread increment.
  void _handleSystemSentinel(
    String sentinel,
    String conversationId,
    String myUserId,
  ) {
    if (conversationId.isEmpty) return;
    final text = ChatMessage.translateSystemSentinel(
      sentinel,
      myUserId: myUserId,
    );
    if (text != null) {
      ref.read(chatProvider.notifier).addSystemEvent(conversationId, text);
    }
  }

  void _handleNewMessage(Map<String, dynamic> json, String myUserId) {
    final rawContent = json['content'] as String;
    final fromUserId = json['from_user_id'] as String;
    final fromDeviceId = json['from_device_id'] as int?;
    final conversationId = json['conversation_id'] as String;
    final timestamp = json['timestamp'] as String;
    final senderUsername = json['from_username'] as String;
    final messageId = json['message_id'] as String? ?? '';

    // System message sentinel -- render as an in-chat event pill and skip the
    // normal decrypt/preview pipeline entirely (#663).
    if (rawContent.startsWith(_systemPrefix)) {
      _handleSystemSentinel(rawContent, conversationId, myUserId);
      return;
    }

    // (#26) Sync Hive check detects offline-queue replays without false positives;
    // genuinely-new messages (box-miss) always return false.
    final alreadySeen =
        messageId.isNotEmpty &&
        MessageCache.isMessageCachedSync(conversationId, messageId);

    final cryptoState = ref.read(cryptoProvider);
    final conversation = ref
        .read(conversationsProvider)
        .conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final isKnownConversation = conversation != null;

    // #557: server marks replay frames `undecryptable: true` when this device
    // has no per-device ciphertext row. Handle as device-mismatch placeholder.
    if (json['undecryptable'] == true) {
      _handleUndecryptableFrame(
        json,
        myUserId,
        conversationId,
        timestamp,
        senderUsername,
        isKnownConversation,
      );
      return;
    }

    // #434: detect plaintext payloads up-front so the "Securing message..."
    // placeholder is never shown for content that doesn't need decryption.
    final isGroupEncryptedWire = rawContent.startsWith(groupEncryptedPrefix);
    final isPlaintextGroup = _detectPlaintextGroup(
      conversation,
      isGroupEncryptedWire,
    );
    final isObviouslyPlaintext = _detectObviouslyPlaintext(
      isGroupEncryptedWire,
      rawContent,
    );

    if (isPlaintextGroup ||
        (isObviouslyPlaintext && !cryptoState.isInitialized)) {
      _deliverPlaintextMessage(
        _MessageDeliveryParams(
          json: json,
          rawContent: rawContent,
          myUserId: myUserId,
          conversationId: conversationId,
          timestamp: timestamp,
          senderUsername: senderUsername,
          fromUserId: fromUserId,
          alreadySeen: alreadySeen,
        ),
        isKnownConversation,
      );
      return;
    }

    if (cryptoState.isInitialized) {
      _deliverEncryptedMessageNow(
        _MessageDeliveryParams(
          json: json,
          rawContent: rawContent,
          myUserId: myUserId,
          conversationId: conversationId,
          timestamp: timestamp,
          senderUsername: senderUsername,
          fromUserId: fromUserId,
          alreadySeen: alreadySeen,
        ),
        fromDeviceId,
      );
    } else {
      _queueEncryptedMessageForLater(
        json,
        myUserId,
        conversationId,
        timestamp,
        senderUsername,
      );
    }

    // Full reload only for unknown convs; existing ones use onNewMessage.
    if (!isKnownConversation) {
      ref.read(conversationsProvider.notifier).loadConversations();
    }

    // Crypto-not-ready: notify on raw plaintext; otherwise notification fires
    // post-decrypt inside _decryptAndDeliverWithPreview.
    if (!cryptoState.isInitialized && fromUserId != myUserId && !alreadySeen) {
      _notifyIfAllowed(conversationId, senderUsername, rawContent);
    }
  }

  bool _detectPlaintextGroup(
    Conversation? conversation,
    bool isGroupEncryptedWire,
  ) {
    return (conversation?.isGroup ?? false) &&
        !(conversation?.isEncrypted ?? false) &&
        !isGroupEncryptedWire;
  }

  bool _detectObviouslyPlaintext(bool isGroupEncryptedWire, String rawContent) {
    return !isGroupEncryptedWire && !looksEncrypted(rawContent);
  }

  void _handleUndecryptableFrame(
    Map<String, dynamic> json,
    String myUserId,
    String conversationId,
    String timestamp,
    String senderUsername,
    bool isKnownConversation,
  ) {
    final placeholder = ChatMessage.fromServerJson({
      ...json,
      'content': '[Encrypted for another device of this account]',
    }, myUserId).copyWith(isEncrypted: true);
    ref.read(chatProvider.notifier).addMessage(placeholder);
    ref
        .read(conversationsProvider.notifier)
        .onNewMessage(
          conversationId: conversationId,
          content: '[Encrypted]',
          timestamp: timestamp,
          senderUsername: senderUsername,
        );
    if (!isKnownConversation) {
      ref.read(conversationsProvider.notifier).loadConversations();
    }
  }

  void _deliverPlaintextMessage(
    _MessageDeliveryParams params,
    bool isKnownConversation,
  ) {
    final msg = ChatMessage.fromServerJson(params.json, params.myUserId);
    ref.read(chatProvider.notifier).addMessage(msg);
    if (!msg.id.startsWith('pending_')) {
      MessageCache.cacheMessages(params.conversationId, [msg]);
    }
    ref
        .read(conversationsProvider.notifier)
        .onNewMessage(
          conversationId: params.conversationId,
          content: params.rawContent,
          timestamp: params.timestamp,
          senderUsername: params.senderUsername,
          // #26: replayed messages (already in cache) must not re-bump unread.
          incrementUnread: !params.alreadySeen,
        );
    if (!isKnownConversation) {
      ref.read(conversationsProvider.notifier).loadConversations();
    }
    // #26: don't re-notify for messages the user already saw.
    if (params.fromUserId != params.myUserId && !params.alreadySeen) {
      _notifyIfAllowed(
        params.conversationId,
        params.senderUsername,
        params.rawContent,
      );
    }
  }

  void _deliverEncryptedMessageNow(
    _MessageDeliveryParams params,
    int? fromDeviceId,
  ) {
    final crypto = ref.read(cryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    crypto.setToken(token);
    _decryptAndDeliverWithPreview(
      crypto,
      params.json,
      params.rawContent,
      params.fromUserId,
      params.myUserId,
      params.conversationId,
      params.timestamp,
      params.senderUsername,
      fromDeviceId: fromDeviceId,
      alreadySeen: params.alreadySeen,
    );
  }

  void _queueEncryptedMessageForLater(
    Map<String, dynamic> json,
    String myUserId,
    String conversationId,
    String timestamp,
    String senderUsername,
  ) {
    // (#430) Placeholder 'Securing message...' is recognised by chat_provider
    // and replaced in-place when the queue drains.
    final placeholder = ChatMessage.fromServerJson({
      ...json,
      'content': 'Securing message...',
    }, myUserId).copyWith(isEncrypted: true);
    ref.read(chatProvider.notifier).addMessage(placeholder);

    // (#830) Bind queue entry to current user — prevents leak on re-login.
    _enqueuePendingDecrypt(json, myUserId);

    ref
        .read(conversationsProvider.notifier)
        .onNewMessage(
          conversationId: conversationId,
          content: '[Encrypted]',
          timestamp: timestamp,
          senderUsername: senderUsername,
        );
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

  void _handleMessageExpired(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String;
    final messageId = json['message_id'] as String;
    ref.read(chatProvider.notifier).deleteMessage(conversationId, messageId);
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
}
