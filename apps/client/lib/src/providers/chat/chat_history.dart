part of 'chat_provider.dart';

/// History loading + decryption pipeline for the chat notifier. Covers:
/// the Hive-cached fast-path (`loadFromCache`, `hydrateStatusFromCache`)
/// shown before the network catches up; the paginated REST fetch
/// (`loadHistoryWithUserId`) that hydrates older messages; and the
/// per-message decrypt dispatcher (1:1 Double Ratchet + GRP1/GRP2 group
/// envelopes) used by the fetch path.
///
/// Mixed into [Chat]. Reads `_serverUrl` from the facade for the API
/// origin; mutates `state` via the standard Notifier setter.
mixin ChatHistoryMixin on Notifier<ChatState> {
  /// The active server origin. Provided by [Chat].
  String get _serverUrl;

  /// Load cached messages from Hive for instant display before server fetch.
  Future<void> loadFromCache(String conversationId, String myUserId) async {
    final cached = await MessageCache.getCachedMessages(
      conversationId,
      myUserId,
    );
    if (cached.isEmpty) return;
    _mergeMessages(conversationId, cached);
  }

  /// Hydrate per-conversation last-message status from Hive on cold start.
  ///
  /// Reads only the most-recent cached message for each conversation so that
  /// the conversation tile can show the correct tick (sent/delivered/read)
  /// before the WS read_receipt stream catches up (#573). Skips conversations
  /// that already have in-memory messages (e.g. the active chat panel).
  Future<void> hydrateStatusFromCache(
    List<String> conversationIds,
    String myUserId,
  ) async {
    for (final convId in conversationIds) {
      // Skip convs already populated (chat panel opened this session).
      if (state.messagesByConversation.containsKey(convId)) continue;
      final latest = await MessageCache.getLatestCachedMessage(
        convId,
        myUserId,
      );
      if (latest == null) continue;
      // Only inject our own sent messages — the tick is only shown for isMine.
      if (!latest.isMine) continue;
      state = state.withMessage(latest);
    }
  }

  /// Load history with the user's own ID for isMine determination.
  /// If [crypto] is provided, attempts to decrypt encrypted messages.
  /// Set [isGroup] to true to skip 1:1 decryption. If [groupCrypto] is
  /// provided, group-encrypted messages (prefixed with `GRP1:`) are
  /// decrypted using the AES-256-GCM group key.
  Future<void> loadHistoryWithUserId(
    String conversationId,
    String token,
    String myUserId, {
    String? channelId,
    String? before,
    CryptoService? crypto,
    bool isGroup = false,
    GroupCryptoService? groupCrypto,
  }) async {
    final historyKey = '$conversationId:${channelId ?? ''}';
    if (state.isLoadingHistory(conversationId, channelId: channelId)) return;

    _setLoadingHistory(historyKey, true);

    try {
      // (#557) Pass device_id so server returns device-scoped ciphertexts.
      final localDeviceId = crypto?.deviceId;
      final url = _buildHistoryUrl(
        conversationId,
        channelId,
        before,
        deviceId: localDeviceId,
      );
      final response = await _fetchHistory(url);

      if (response.statusCode == 200) {
        final messagesList = _parseMessagesList(response.body);
        final newMessages = await _processHistoryMessages(
          messagesList,
          myUserId,
          isGroup: isGroup,
          crypto: crypto,
          groupCrypto: groupCrypto,
          conversationId: conversationId,
        );
        _mergeMessages(conversationId, newMessages, channelId: channelId);
        MessageCache.cacheMessages(conversationId, newMessages);
      }
    } catch (e) {
      debugPrint(
        '[Chat] loadHistoryWithUserId failed for '
        '$conversationId: $e',
      );
      DebugLogService.instance.log(
        LogLevel.error,
        'Chat',
        'loadHistory failed for $conversationId: $e',
      );
    } finally {
      _setLoadingHistory(historyKey, false);
    }
  }

  String _buildHistoryUrl(
    String conversationId,
    String? channelId,
    String? before, {
    int? deviceId,
  }) {
    var url = '$_serverUrl/api/messages/$conversationId?limit=50';
    if (channelId != null && channelId.isNotEmpty) {
      url += '&channel_id=${Uri.encodeComponent(channelId)}';
    }
    if (before != null) {
      url += '&before=${Uri.encodeComponent(before)}';
    }
    // (#557) device_id scopes server LEFT JOIN to this device's ratchet.
    if (deviceId != null && deviceId > 0) {
      url += '&device_id=$deviceId';
    }
    return url;
  }

  Future<http.Response> _fetchHistory(String url) {
    return ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (currentToken) => http.get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $currentToken',
              'Content-Type': 'application/json',
            },
          ),
        );
  }

  List<dynamic> _parseMessagesList(String body) {
    final decoded = jsonDecode(body);
    return decoded is List ? decoded : (decoded['messages'] as List? ?? []);
  }

  Future<List<ChatMessage>> _processHistoryMessages(
    List<dynamic> messagesList,
    String myUserId, {
    required bool isGroup,
    CryptoService? crypto,
    GroupCryptoService? groupCrypto,
    String? conversationId,
  }) async {
    final newMessages = <ChatMessage>[];
    for (final e in messagesList) {
      final json = e as Map<String, dynamic>;
      var msg = ChatMessage.fromServerJson(json, myUserId);
      // #557: pull the originating device id off the row so we route to the
      // right per-device ratchet. Null = legacy row (single-device era).
      final fromDeviceId = json['from_device_id'] as int?;
      msg = await _decryptIfNeeded(
        msg,
        myUserId: myUserId,
        isGroup: isGroup,
        crypto: crypto,
        groupCrypto: groupCrypto,
        conversationId: conversationId,
        fromDeviceId: fromDeviceId,
      );
      newMessages.add(msg);
    }

    // Update conversation preview with the latest decrypted message so the
    // conversation list shows plaintext instead of "Encrypted message".
    if (newMessages.isNotEmpty && conversationId != null) {
      final latest = newMessages.last;
      if (!looksEncrypted(latest.content)) {
        ref
            .read(conversationsProvider.notifier)
            .updateDecryptedPreview(conversationId, latest.content);
      }
    }

    return newMessages;
  }

  /// History-path group decrypt. Dispatches by wire prefix:
  ///   - `GRP2:` → fetch the sender's per-device Ed25519 verify key and
  ///     run the signed AEAD path.
  ///   - `GRP1:` → legacy unsigned path, refused when the cached
  ///     envelope's `min_wire_version` has been bumped to 2 (audit
  ///     OQ-11: downgrade-attack mitigation).
  Future<ChatMessage> _decryptGroupMessage(
    ChatMessage msg,
    CryptoService? crypto,
    GroupCryptoService? groupCrypto,
    String? conversationId,
    int? fromDeviceId,
  ) async {
    if (groupCrypto == null || conversationId == null) {
      return msg.copyWith(
        content: '[Encrypted group message]',
        isEncrypted: true,
      );
    }
    try {
      final keyResult = await groupCrypto.getGroupKey(conversationId);
      if (keyResult == null) {
        return msg.copyWith(
          content: '[Encrypted group message - key unavailable]',
          isEncrypted: true,
        );
      }
      final (_, keyBase64) = keyResult;
      final minWireVersion =
          groupCrypto.cachedMinWireVersion(conversationId) ?? 1;

      if (msg.content.startsWith(groupEncryptedPrefixV2)) {
        if (crypto == null) {
          return msg.copyWith(
            content: _kCouldNotVerifySender,
            isEncrypted: true,
          );
        }
        final senderVerifyKey = await crypto.getSenderVerifyKeyForDevice(
          msg.fromUserId,
          fromDeviceId,
        );
        if (senderVerifyKey == null) {
          return msg.copyWith(
            content: _kCouldNotVerifySender,
            isEncrypted: true,
          );
        }
        try {
          final decrypted =
              await GroupCryptoService.verifyAndDecryptGroupMessageV2(
                ciphertextWithPrefix: msg.content,
                keyBase64: keyBase64,
                expectedConversationIdBytes: uuidStringToBytes(conversationId),
                expectedMessageIdBytes: uuidStringToBytes(msg.id),
                senderVerifyKey: senderVerifyKey,
              );
          return msg.copyWith(content: decrypted, isEncrypted: true);
        } on GroupSenderSignatureException catch (e) {
          DebugLogService.instance.log(
            LogLevel.warning,
            'Chat',
            'GRP2 signature failed for ${msg.id}: $e',
          );
          return msg.copyWith(
            content: _kCouldNotVerifySender,
            isEncrypted: true,
          );
        }
      }

      // GRP1 path. Refuse when the envelope is pinned to GRP2.
      if (minWireVersion >= 2) {
        return msg.copyWith(content: _kCouldNotVerifySender, isEncrypted: true);
      }
      final decrypted = await GroupCryptoService.decryptGroupMessage(
        msg.content,
        keyBase64,
      );
      return msg.copyWith(content: decrypted, isEncrypted: true);
    } catch (e) {
      debugPrint('[Chat] Group history decrypt failed for ${msg.id}: $e');
      DebugLogService.instance.log(
        LogLevel.warning,
        'Chat',
        'Group decrypt failed for ${msg.id}: $e',
      );
      return msg.copyWith(
        content: '[Could not decrypt group message]',
        isEncrypted: true,
      );
    }
  }

  Future<ChatMessage> _decryptIfNeeded(
    ChatMessage msg, {
    required String myUserId,
    required bool isGroup,
    CryptoService? crypto,
    GroupCryptoService? groupCrypto,
    String? conversationId,
    int? fromDeviceId,
  }) async {
    // Group-encrypted messages (prefixed with GRP1: or GRP2:)
    if (msg.content.startsWith(groupEncryptedPrefix) ||
        msg.content.startsWith(groupEncryptedPrefixV2)) {
      return _decryptGroupMessage(
        msg,
        crypto,
        groupCrypto,
        conversationId,
        fromDeviceId,
      );
    }

    // Skip decryption for non-encrypted group messages
    if (isGroup || !looksEncrypted(msg.content)) return msg;

    // Cache first: Ratchet keys are consumed once; re-decryption is impossible.
    if (conversationId != null) {
      final cached = await MessageCache.getCachedMessage(
        conversationId,
        msg.id,
        myUserId,
      );
      if (cached != null && !looksEncrypted(cached.content)) {
        return cached.copyWith(isEncrypted: true);
      }
    }

    if (crypto == null) {
      return msg.copyWith(content: '[Encrypted history]', isEncrypted: true);
    }

    // (#557) decryptHistoryMessage: no new session, returns null on fail;
    // fromDeviceId selects per-device ratchet (null → legacy key).
    final decrypted = await crypto.decryptHistoryMessage(
      msg.fromUserId,
      msg.content,
      fromDeviceId: fromDeviceId,
    );
    if (decrypted != null) {
      return msg.copyWith(content: decrypted, isEncrypted: true);
    }
    return msg.copyWith(
      content: '[Message encrypted - history unavailable]',
      isEncrypted: true,
    );
  }

  void _setLoadingHistory(String historyKey, bool loading) {
    final updatedLoading = Map<String, bool>.from(state.loadingHistory);
    updatedLoading[historyKey] = loading;
    state = state.copyWith(loadingHistory: updatedLoading);
  }

  void _mergeMessages(
    String conversationId,
    List<ChatMessage> newMessages, {
    String? channelId,
  }) {
    // Only clone the affected conversation's list; other entries stay
    // reference-equal so Riverpod selectors for unaffected convs don't rebuild.
    final existing = state.messagesByConversation[conversationId] ?? [];
    final existingIds = existing.map((m) => m.id).toSet();

    final deduped = newMessages
        .where((m) => !existingIds.contains(m.id))
        .toList();

    var merged = [...deduped, ...existing]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Trim to cap, keeping newest messages.
    if (merged.length > _maxMessagesPerConv) {
      merged = merged.sublist(merged.length - _maxMessagesPerConv);
    }

    final hasMoreKey = '$conversationId:${channelId ?? ''}';

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: merged,
      },
      messageIdIndex: {
        ...state._messageIdIndex,
        conversationId: merged.map((m) => m.id).toSet(),
      },
      hasMore: {...state.hasMore, hasMoreKey: newMessages.length >= 50},
    );
  }
}
