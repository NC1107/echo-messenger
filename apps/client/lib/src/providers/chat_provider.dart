import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../services/crypto_service.dart';
import '../services/debug_log_service.dart';
import '../services/group_crypto_service.dart';
import '../services/message_cache.dart';
import '../utils/crypto_utils.dart';
import 'auth_provider.dart';
import 'conversations_provider.dart';
import 'server_url_provider.dart';

/// Placeholder content strings emitted by ws_message_handler.dart while a
/// message is awaiting decryption.  When [ChatState.withMessage] sees an
/// inbound message whose id collides with an existing entry that matches
/// one of these (and is still flagged isEncrypted), the entry is replaced
/// in place rather than dedup-dropped (#430).  Keep in sync with the emit
/// sites in ws_message_handler.dart.
const _placeholderContents = <String>{
  'Securing message...',
  '[Encrypted for another device of this account]',
};

bool _isPlaceholderContent(String c) =>
    _placeholderContents.contains(c) || c.startsWith('[Could not decrypt');

class ChatState {
  /// Messages keyed by conversation ID.
  final Map<String, List<ChatMessage>> messagesByConversation;

  /// O(1) dedup index: message IDs per conversation.
  final Map<String, Set<String>> _messageIdIndex;

  /// Whether history is currently loading for a conversation.
  /// Key format: conversationId:channelId (channelId empty for full conversation).
  final Map<String, bool> loadingHistory;

  /// Whether there are more messages to load (for pagination).
  /// Key format: conversationId:channelId (channelId empty for full conversation).
  final Map<String, bool> hasMore;

  /// The message being replied to (shown in the input bar).
  final ChatMessage? replyToMessage;

  const ChatState({
    this.messagesByConversation = const {},
    Map<String, Set<String>> messageIdIndex = const {},
    this.loadingHistory = const {},
    this.hasMore = const {},
    this.replyToMessage,
  }) : _messageIdIndex = messageIdIndex;

  /// Get messages for a conversation ID.
  List<ChatMessage> messagesForConversation(String conversationId) {
    return messagesByConversation[conversationId] ?? [];
  }

  String _historyKey(String conversationId, String? channelId) {
    return '$conversationId:${channelId ?? ''}';
  }

  List<ChatMessage> messagesForConversationChannel(
    String conversationId, {
    String? channelId,
    bool includeUnchanneled = false,
  }) {
    final messages = messagesForConversation(conversationId);
    if (channelId == null || channelId.isEmpty) {
      return messages;
    }
    return messages.where((m) {
      if (m.channelId == channelId) {
        return true;
      }
      return includeUnchanneled &&
          (m.channelId == null || m.channelId!.isEmpty);
    }).toList();
  }

  bool isLoadingHistory(String conversationId, {String? channelId}) {
    return loadingHistory[_historyKey(conversationId, channelId)] ?? false;
  }

  bool conversationHasMore(String conversationId, {String? channelId}) {
    return hasMore[_historyKey(conversationId, channelId)] ?? true;
  }

  ChatState withMessage(ChatMessage msg) {
    // Work with the current per-conversation data only; other entries stay
    // reference-equal so Riverpod selectors for unaffected convs don't rebuild.
    var updatedConvMap = messagesByConversation;
    var updatedIndexMap = _messageIdIndex;

    if (msg.conversationId.isNotEmpty) {
      final ids = Set<String>.from(
        updatedIndexMap[msg.conversationId] ?? <String>{},
      );
      // O(1) deduplicate by ID
      if (!ids.contains(msg.id)) {
        final existing = updatedConvMap[msg.conversationId] ?? [];
        var updated = [...existing, msg];
        // Trim to cap, keeping newest messages.
        if (updated.length > _maxMessagesPerConv) {
          updated = updated.sublist(updated.length - _maxMessagesPerConv);
        }
        ids.add(msg.id);
        // Rebuild index from trimmed list to stay consistent.
        final newIds = updated.map((m) => m.id).toSet();
        updatedConvMap = {...updatedConvMap, msg.conversationId: updated};
        updatedIndexMap = {...updatedIndexMap, msg.conversationId: newIds};
      } else {
        // Id collision: existing entry might be a decrypt-pending
        // placeholder (#430).  Replace it in place when isEncrypted
        // and the content matches a known placeholder string.  The
        // index already contains msg.id so no map mutation is needed.
        final existing = updatedConvMap[msg.conversationId] ?? const [];
        final idx = existing.indexWhere((m) => m.id == msg.id);
        if (idx >= 0 &&
            existing[idx].isEncrypted &&
            _isPlaceholderContent(existing[idx].content)) {
          final replaced = [...existing]..[idx] = msg;
          updatedConvMap = {...updatedConvMap, msg.conversationId: replaced};
        }
      }
    }

    return ChatState(
      messagesByConversation: updatedConvMap,
      messageIdIndex: updatedIndexMap,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
      replyToMessage: replyToMessage,
    );
  }

  ChatState copyWith({
    Map<String, List<ChatMessage>>? messagesByConversation,
    Map<String, Set<String>>? messageIdIndex,
    Map<String, bool>? loadingHistory,
    Map<String, bool>? hasMore,
    ChatMessage? replyToMessage,
    bool clearReply = false,
  }) {
    return ChatState(
      messagesByConversation:
          messagesByConversation ?? this.messagesByConversation,
      messageIdIndex: messageIdIndex ?? _messageIdIndex,
      loadingHistory: loadingHistory ?? this.loadingHistory,
      hasMore: hasMore ?? this.hasMore,
      replyToMessage: clearReply
          ? null
          : (replyToMessage ?? this.replyToMessage),
    );
  }
}

/// Maximum messages retained per conversation to bound memory usage.
const _maxMessagesPerConv = 500;

class ChatNotifier extends StateNotifier<ChatState> {
  final Ref ref;

  /// Timers that transition pending messages to failed after 15 seconds
  /// without server confirmation.
  final Map<String, Timer> _sendTimeouts = {};

  ChatNotifier(this.ref) : super(const ChatState());

  String get _serverUrl => ref.read(serverUrlProvider);

  /// Load cached messages from Hive for instant display before server fetch.
  Future<void> loadFromCache(String conversationId, String myUserId) async {
    final cached = await MessageCache.getCachedMessages(
      conversationId,
      myUserId,
    );
    if (cached.isEmpty) return;
    _mergeMessages(conversationId, cached);
  }

  void addMessage(ChatMessage msg) {
    var newState = state.withMessage(msg);
    // Increment reply count on the parent when an incoming message is a reply.
    if (msg.replyToId != null) {
      newState = _incrementReplyCount(
        newState,
        msg.conversationId,
        msg.replyToId!,
      );
    }
    state = newState;
  }

  /// Set the message being replied to (shown in the input bar).
  void setReplyTo(ChatMessage message) {
    state = state.copyWith(replyToMessage: message);
  }

  /// Clear the active reply.
  void clearReplyTo() {
    state = state.copyWith(clearReply: true);
  }

  void addSystemEvent(String conversationId, String event) {
    final existing = state.messagesForConversation(conversationId);
    if (existing.isNotEmpty) {
      final last = existing.last;
      // Avoid duplicate timeline rows when local state and WS echo race.
      if (last.fromUserId == '__system__' && last.content == event) {
        return;
      }
    }

    final msg = ChatMessage(
      id: 'system_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: '__system__',
      fromUsername: 'System',
      conversationId: conversationId,
      content: event,
      timestamp: DateTime.now().toIso8601String(),
      isMine: false,
      status: MessageStatus.sent,
    );
    state = state.withMessage(msg);
  }

  void addOptimistic(
    String peerUserId,
    String content,
    String myUserId, {
    String conversationId = '',
    String? channelId,
    String? replyToId,
    String? replyToContent,
    String? replyToUsername,
  }) {
    final pendingId = 'pending_${DateTime.now().millisecondsSinceEpoch}';
    final msg = ChatMessage(
      id: pendingId,
      fromUserId: myUserId,
      fromUsername: 'You',
      conversationId: conversationId,
      channelId: channelId,
      content: content,
      timestamp: DateTime.now().toIso8601String(),
      isMine: true,
      status: MessageStatus.sending,
      replyToId: replyToId,
      replyToContent: replyToContent,
      replyToUsername: replyToUsername,
      failedContent: content, // preserve for retry if send times out
    );
    var newState = state.withMessage(msg);

    // Optimistically increment reply count on the parent message.
    if (replyToId != null) {
      newState = _incrementReplyCount(newState, conversationId, replyToId);
    }

    state = newState;

    // Cancel any existing timer for this ID (defensive, prevents orphans).
    _sendTimeouts.remove(pendingId)?.cancel();
    // Start a 15-second timeout — if no confirmSent() arrives, mark failed.
    _sendTimeouts[pendingId] = Timer(const Duration(seconds: 15), () {
      // Atomically remove: if already cancelled by confirmSent(), skip.
      final removed = _sendTimeouts.remove(pendingId);
      if (removed == null) return; // timer was already cancelled
      _transitionToFailed(conversationId, pendingId, content);
    });
  }

  /// Increment the reply count on a parent message by 1.
  ChatState _incrementReplyCount(
    ChatState s,
    String conversationId,
    String parentId,
  ) {
    final messages = s.messagesForConversation(conversationId);
    final idx = messages.indexWhere((m) => m.id == parentId);
    if (idx == -1) return s;
    final parent = messages[idx];
    final updated = parent.copyWith(replyCount: parent.replyCount + 1);
    final newList = List<ChatMessage>.from(messages);
    newList[idx] = updated;
    return s.copyWith(
      messagesByConversation: {
        ...s.messagesByConversation,
        conversationId: newList,
      },
    );
  }

  /// Transition a pending message to failed status after send timeout.
  void _transitionToFailed(
    String conversationId,
    String pendingId,
    String originalContent,
  ) {
    final messages = state.messagesForConversation(conversationId);
    final idx = messages.indexWhere((m) => m.id == pendingId);
    if (idx == -1) return;
    final msg = messages[idx];
    if (msg.status != MessageStatus.sending) return;

    final updated = msg.copyWith(
      status: MessageStatus.failed,
      content: 'Message may not have been delivered. Tap to retry.',
      failedContent: originalContent,
    );
    final updatedList = List<ChatMessage>.from(messages);
    updatedList[idx] = updated;
    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updatedList,
      },
    );
  }

  void confirmSent(
    String messageId,
    String conversationId,
    String timestamp, {
    String? channelId,
    DateTime? expiresAt,
  }) {
    // Replace the most recent pending/sending message in this conversation
    // with the server-assigned ID so that delivery receipts can match it.
    // Only clone the affected conversation's list; other entries stay
    // reference-equal so Riverpod selectors for unaffected convs don't rebuild.
    final messages = state.messagesByConversation[conversationId];
    if (messages != null) {
      final (replacedPendingId, updatedMessages) = _replacePendingMessage(
        messages,
        messageId,
        timestamp,
        channelId,
        expiresAt,
      );
      // Cancel only the timer for the specific pending message that was
      // confirmed — not all pending timers in the conversation.
      if (replacedPendingId != null) {
        _sendTimeouts.remove(replacedPendingId)?.cancel();
      }

      if (updatedMessages != null) {
        // Rebuild the index incrementally: swap old pending ID for new one.
        final newIds = updatedMessages.map((m) => m.id).toSet();
        state = state.copyWith(
          messagesByConversation: {
            ...state.messagesByConversation,
            conversationId: updatedMessages,
          },
          messageIdIndex: {...state._messageIdIndex, conversationId: newIds},
        );
      }
    }

    // Cache the confirmed message
    final confirmed = state
        .messagesForConversation(conversationId)
        .where((m) => m.id == messageId)
        .toList();
    if (confirmed.isNotEmpty) {
      MessageCache.cacheMessages(conversationId, confirmed);
    }
  }

  /// Replace the oldest pending message with the confirmed server ID.
  ///
  /// Uses FIFO order (oldest first) so that when multiple messages are sent
  /// in rapid succession (e.g. attachment + caption), server confirmations
  /// match the correct pending message regardless of arrival timing.
  /// Returns a record of (pendingId, updatedList); both are null when no
  /// pending message was found.
  (String?, List<ChatMessage>?) _replacePendingMessage(
    List<ChatMessage> messages,
    String messageId,
    String timestamp,
    String? channelId,
    DateTime? expiresAt,
  ) {
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.id.startsWith('pending_') &&
          msg.isMine &&
          msg.status == MessageStatus.sending &&
          (channelId == null || msg.channelId == channelId)) {
        final pendingId = msg.id;
        final updatedMessages = List<ChatMessage>.from(messages);
        updatedMessages[i] = msg.copyWith(
          id: messageId,
          timestamp: timestamp,
          status: MessageStatus.sent,
          channelId: channelId ?? msg.channelId,
          expiresAt: expiresAt ?? msg.expiresAt,
        );
        return (pendingId, updatedMessages);
      }
    }
    return (null, null);
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
      // #557: pass our local device_id so the server can return device-aware
      // ciphertexts via `message_device_contents`. Without this the server
      // returns the canonical (originating-device) wire and secondary
      // devices fail to decrypt their own DM history.
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
    // #557: device_id lets the server LEFT JOIN
    // `message_device_contents` and return the row scoped to this device's
    // ratchet rather than the originating device's wire.
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

  Future<ChatMessage> _decryptGroupMessage(
    ChatMessage msg,
    GroupCryptoService? groupCrypto,
    String? conversationId,
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
    // Group-encrypted messages (prefixed with GRP1:)
    if (msg.content.startsWith(groupEncryptedPrefix)) {
      return _decryptGroupMessage(msg, groupCrypto, conversationId);
    }

    // Skip decryption for non-encrypted group messages
    if (isGroup || !looksEncrypted(msg.content)) return msg;

    // Check Hive cache first — Double Ratchet keys are consumed once and
    // cannot be re-derived, so previously decrypted messages must come from
    // the cache rather than re-decryption.
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

    // Use decryptHistoryMessage which never creates new sessions and returns
    // null on failure instead of throwing.
    // #557: pass the originating device so the right per-device ratchet is
    // selected; null falls back to the legacy peer-only session key.
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

  /// Add a reaction to a message.
  void addReaction(String conversationId, Reaction reaction) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == reaction.messageId) {
        final reactions = List<Reaction>.from(msg.reactions);
        // Remove existing reaction from same user with same emoji (toggle)
        reactions.removeWhere(
          (r) => r.userId == reaction.userId && r.emoji == reaction.emoji,
        );
        reactions.add(reaction);
        return msg.copyWith(reactions: reactions);
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );
  }

  /// Remove a reaction from a message.
  void removeReaction(
    String conversationId,
    String messageId,
    String userId,
    String emoji,
  ) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        final reactions = List<Reaction>.from(msg.reactions);
        reactions.removeWhere((r) => r.userId == userId && r.emoji == emoji);
        return msg.copyWith(reactions: reactions);
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );
  }

  /// Update message status (sent, delivered).
  void updateMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(status: status);
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );
  }

  /// Mark all of my sent/delivered messages in a conversation as read.
  void markConversationRead(String conversationId) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.isMine &&
          (msg.status == MessageStatus.sent ||
              msg.status == MessageStatus.delivered)) {
        return msg.copyWith(status: MessageStatus.read);
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );
  }

  /// Delete a message from local state.
  void deleteMessage(String conversationId, String messageId) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.where((msg) => msg.id != messageId).toList();

    // Remove the deleted ID from the index incrementally.
    final existingIds = state._messageIdIndex[conversationId] ?? const {};
    final newIds = Set<String>.from(existingIds)..remove(messageId);

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
      messageIdIndex: {...state._messageIdIndex, conversationId: newIds},
    );
  }

  /// Remove all cached messages for a conversation (e.g. after leaving it).
  void clearConversation(String conversationId) {
    // Cancel any pending send timers for this conversation.
    final pending = state
        .messagesForConversation(conversationId)
        .where((m) => m.id.startsWith('pending_'));
    for (final m in pending) {
      _sendTimeouts.remove(m.id)?.cancel();
    }

    // Remove the conversation entry from both maps via full copies (removal
    // cannot be expressed with spread syntax); this path is infrequent
    // (leave/clear) so the cost is acceptable.
    final newConvMap = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    )..remove(conversationId);
    final newIndexMap = Map<String, Set<String>>.from(state._messageIdIndex)
      ..remove(conversationId);

    state = state.copyWith(
      messagesByConversation: newConvMap,
      messageIdIndex: newIndexMap,
    );
  }

  /// Update a message's content and set editedAt.
  void editMessage(
    String conversationId,
    String messageId,
    String newContent, {
    String? editedAt,
  }) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(
          content: newContent,
          editedAt: editedAt ?? DateTime.now().toIso8601String(),
        );
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );

    // Persist the edit to the local Hive cache so it survives app restart.
    final edited = updated.where((m) => m.id == messageId).toList();
    if (edited.isNotEmpty) {
      MessageCache.cacheMessages(conversationId, edited);
    }
  }

  /// Update a message's pin state in local state.
  void updateMessagePin(
    String conversationId,
    String messageId,
    String? pinnedById,
    DateTime? pinnedAt,
  ) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(pinnedById: pinnedById, pinnedAt: pinnedAt);
      }
      return msg;
    }).toList();

    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );
  }

  /// Forward a message to a different conversation.
  ///
  /// Prepends "[Forwarded] " to the content and delegates the actual wire
  /// send to [sender], which is supplied by the caller to avoid a circular
  /// dependency (websocket_provider already imports chat_provider).
  Future<void> forwardMessage(
    String messageContent,
    String targetConversationId,
    Future<void> Function(String forwardedContent) sender,
  ) async {
    final forwarded = '[Forwarded] $messageContent';
    await sender(forwarded);
  }

  void clear() {
    // Cancel all pending send-timeout timers to prevent orphaned callbacks.
    for (final timer in _sendTimeouts.values) {
      timer.cancel();
    }
    _sendTimeouts.clear();
    state = const ChatState();
  }

  @override
  void dispose() {
    // Cancel any remaining timers so they don't fire after disposal.
    for (final timer in _sendTimeouts.values) {
      timer.cancel();
    }
    _sendTimeouts.clear();
    super.dispose();
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(ref);
});
