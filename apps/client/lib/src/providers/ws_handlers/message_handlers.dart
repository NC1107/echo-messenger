part of '../ws_message_handler.dart';

/// Sentinel prefix used by system messages (#663).
const String _systemPrefix = '__system__:';

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

  /// Parse a `__system__:member_joined:<uuid>:<username>` sentinel and emit
  /// an in-chat system event pill. No preview update, no unread increment.
  void _handleSystemSentinel(String sentinel, String conversationId) {
    if (conversationId.isEmpty) return;
    const joinedTag = '__system__:member_joined:';
    if (sentinel.startsWith(joinedTag)) {
      final rest = sentinel.substring(joinedTag.length);
      final colonIdx = rest.indexOf(':');
      final username = colonIdx >= 0 ? rest.substring(colonIdx + 1) : rest;
      if (username.isNotEmpty) {
        ref
            .read(chatProvider.notifier)
            .addSystemEvent(conversationId, '$username joined the group');
      }
    }
  }

  void _handleNewMessage(Map<String, dynamic> json, String myUserId) {
    final rawContent = json['content'] as String;
    final fromUserId = json['from_user_id'] as String;
    final fromDeviceId = json['from_device_id'] as int?;
    final conversationId = json['conversation_id'] as String;
    final timestamp = json['timestamp'] as String;
    final senderUsername = json['from_username'] as String;

    // System message sentinel -- render as an in-chat event pill and skip the
    // normal decrypt/preview pipeline entirely (#663).
    if (rawContent.startsWith(_systemPrefix)) {
      _handleSystemSentinel(rawContent, conversationId);
      return;
    }

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
    // The literal '[Encrypted for another device of this account]' string is
    // recognised by chat_provider.dart's `_placeholderContents` (#430).
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
