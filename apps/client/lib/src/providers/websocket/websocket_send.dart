part of '../websocket_provider.dart';

/// Send-path slice of [WebSocketNotifier]. Owns DM and group send-frame
/// construction, the multi-device fanout, the encryption fallback chain,
/// the group key self-heal, and the friendly-error mapping.
///
/// Wire shape is contract-tested in
/// `test/providers/websocket_wire_shape_test.dart` — do NOT alter the JSON
/// keys, top-level type, or the nested `recipient_device_contents` map
/// shape without coordinating with the server-side parser.
extension WsSend on WebSocketNotifier {
  /// DM send pipeline: encrypt for every recipient device + own devices,
  /// then emit a single `send_message` frame whose multi-device envelope
  /// the server fans out.
  Future<void> _sendDmMessage(
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

  /// Group send pipeline: encrypt if the conversation requires it, else
  /// emit plaintext. Hard-fails (no wire send) on encryption error (#344).
  Future<void> _sendGroupMessage(
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
}

/// Map raw encryption exceptions to user-readable messages.
/// Never surfaces raw exception text — always returns a friendly string.
///
/// Pure free function (no `this`) so the send slice can stay a thin
/// extension and so this can be unit-tested directly if needed.
String _friendlyEncryptionError(Object e) {
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
    return 'Setting up your secure session — please try again in a moment.';
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
