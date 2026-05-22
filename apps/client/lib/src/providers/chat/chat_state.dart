part of 'chat_provider.dart';

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

/// Placeholder shown when an inbound GRP2 group message fails sender-
/// signature verification (or we cannot fetch the sender's verify key).
/// Distinct from "[Could not decrypt…]" because this is a *security*
/// signal rather than a key-out-of-sync transient.
const _kCouldNotVerifySender = '[Could not verify sender]';

bool _isPlaceholderContent(String c) =>
    _placeholderContents.contains(c) || c.startsWith('[Could not decrypt');

/// Maximum messages retained per conversation to bound memory usage.
const _maxMessagesPerConv = 500;

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

  /// Per-conversation count of *consecutive* "[Could not decrypt…]"
  /// placeholders. Resets to 0 when any message in the conversation decrypts
  /// successfully. The chat UI shows an "encryption out of sync — reset?"
  /// banner once this crosses [outOfSyncThreshold]. Audit P0-3.
  final Map<String, int> consecutiveDecryptFailures;

  /// Conversations where at least one GRP2 message has failed sender
  /// signature verification ("[Could not verify sender]"). Distinct
  /// from `consecutiveDecryptFailures` because a sig-fail is a
  /// *security signal*, not a key-out-of-sync transient — no
  /// automatic recovery action is offered and the banner stays
  /// visible until the user resolves it (or the conversation is
  /// closed and reopened). Audit Phase 4 (group recovery UX).
  final Set<String> signatureFailures;

  /// Groups whose latest key version exists on the server but has no
  /// per-user envelope for the current caller — i.e. another member
  /// must rotate us in. Populated when
  /// `GET /api/groups/:id/keys/latest` returns 410 Gone. Drives the
  /// "Refresh key" banner; cleared by `refreshGroupKey` once a
  /// healthy envelope is fetched. Prevents the unkeyed-member
  /// silent-skip bug where rotation completed without an envelope
  /// for this user and the server then served a sentinel placeholder
  /// the client tried to decrypt as a key.
  final Set<String> groupsNeedingRotation;

  /// Threshold at which the per-conversation banner becomes visible.
  /// Three is the audit's recommended default; tuning lives in
  /// `06-recommendations.md`.
  static const int outOfSyncThreshold = 3;

  const ChatState({
    this.messagesByConversation = const {},
    Map<String, Set<String>> messageIdIndex = const {},
    this.loadingHistory = const {},
    this.hasMore = const {},
    this.replyToMessage,
    this.consecutiveDecryptFailures = const {},
    this.signatureFailures = const {},
    this.groupsNeedingRotation = const {},
  }) : _messageIdIndex = messageIdIndex;

  /// True when the named conversation has crossed [outOfSyncThreshold]
  /// consecutive decrypt failures and should render the reset banner.
  bool isConversationOutOfSync(String conversationId) {
    return (consecutiveDecryptFailures[conversationId] ?? 0) >=
        outOfSyncThreshold;
  }

  /// True when the named conversation has at least one unresolved GRP2
  /// signature failure. Renders a danger-banner with no auto-action.
  bool hasSignatureFailure(String conversationId) {
    return signatureFailures.contains(conversationId);
  }

  /// True when the named conversation's latest server-side key version
  /// has no per-user envelope for us — another member must rotate us in.
  /// Drives the "Refresh key" banner.
  bool isGroupAwaitingRotation(String conversationId) {
    return groupsNeedingRotation.contains(conversationId);
  }

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
      // System events (member joined, voice call started, ...) are
      // conversation-level and should appear in every channel view.
      // They have channelId == null because the server never assigns
      // them to a specific channel.
      if (m.isSystemEvent) return true;
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
    var updatedFailures = consecutiveDecryptFailures;
    var updatedSigFailures = signatureFailures;

    if (msg.conversationId.isNotEmpty) {
      final (nextFailures, nextSigFailures) = _trackDecryptFailures(
        msg,
        updatedFailures,
        updatedSigFailures,
      );
      updatedFailures = nextFailures;
      updatedSigFailures = nextSigFailures;

      final (nextConvMap, nextIndexMap) = _appendOrReplaceMessage(
        msg,
        updatedConvMap,
        updatedIndexMap,
      );
      updatedConvMap = nextConvMap;
      updatedIndexMap = nextIndexMap;
    }

    return ChatState(
      messagesByConversation: updatedConvMap,
      messageIdIndex: updatedIndexMap,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
      replyToMessage: replyToMessage,
      consecutiveDecryptFailures: updatedFailures,
      signatureFailures: updatedSigFailures,
      groupsNeedingRotation: groupsNeedingRotation,
    );
  }

  /// Audit P0-3 + Phase 4: track decrypt-failure placeholders so the
  /// chat UI can surface a recovery banner. Two distinct buckets:
  ///   - `consecutiveDecryptFailures` — count "[Could not decrypt…]"
  ///     transients, reset on any genuine decrypt success.
  ///   - `signatureFailures` — sticky set of conversations where a
  ///     "[Could not verify sender]" landed. Cleared only when the
  ///     user closes / reopens the conversation OR an admin rotates
  ///     the key (which also drops the cached envelope).
  (Map<String, int>, Set<String>) _trackDecryptFailures(
    ChatMessage msg,
    Map<String, int> failures,
    Set<String> sigFailures,
  ) {
    final isDecryptFailure = msg.content.startsWith('[Could not decrypt');
    final isSigFailure = msg.content.startsWith('[Could not verify sender');
    final prev = failures[msg.conversationId] ?? 0;

    var nextFailures = failures;
    if (isDecryptFailure) {
      nextFailures = {...failures, msg.conversationId: prev + 1};
    } else if (prev > 0 &&
        !_isPlaceholderContent(msg.content) &&
        !msg.isSystemEvent) {
      // Genuine success after one or more failures — clear the counter.
      nextFailures = {...failures}..remove(msg.conversationId);
    }

    var nextSigFailures = sigFailures;
    if (isSigFailure && !sigFailures.contains(msg.conversationId)) {
      nextSigFailures = {...sigFailures, msg.conversationId};
    }
    return (nextFailures, nextSigFailures);
  }

  /// Append `msg` to its conversation list (deduped + capped) or, when an
  /// existing decrypt-pending placeholder shares the same id (#430),
  /// replace it in place. Returns the updated conv-map and id-index map.
  (Map<String, List<ChatMessage>>, Map<String, Set<String>>)
  _appendOrReplaceMessage(
    ChatMessage msg,
    Map<String, List<ChatMessage>> convMap,
    Map<String, Set<String>> indexMap,
  ) {
    final ids = Set<String>.from(indexMap[msg.conversationId] ?? <String>{});
    if (!ids.contains(msg.id)) {
      final existing = convMap[msg.conversationId] ?? [];
      var updated = [...existing, msg];
      // Trim to cap, keeping newest messages.
      if (updated.length > _maxMessagesPerConv) {
        updated = updated.sublist(updated.length - _maxMessagesPerConv);
      }
      // Rebuild index from trimmed list to stay consistent.
      final newIds = updated.map((m) => m.id).toSet();
      return (
        {...convMap, msg.conversationId: updated},
        {...indexMap, msg.conversationId: newIds},
      );
    }
    // Id collision: existing entry might be a decrypt-pending placeholder
    // (#430). Replace it in place when isEncrypted and the content
    // matches a known placeholder string. The index already contains
    // msg.id so no map mutation is needed.
    final existing = convMap[msg.conversationId] ?? const <ChatMessage>[];
    final idx = existing.indexWhere((m) => m.id == msg.id);
    if (idx >= 0 &&
        existing[idx].isEncrypted &&
        _isPlaceholderContent(existing[idx].content)) {
      final replaced = [...existing]..[idx] = msg;
      return ({...convMap, msg.conversationId: replaced}, indexMap);
    }
    return (convMap, indexMap);
  }

  /// Reset the consecutive-decrypt-failures counter for a conversation.
  /// Called by the "Reset Session" affordance after the user has explicitly
  /// asked to recover. Audit P0-3.
  ChatState withSyncRestored(String conversationId) {
    if (!consecutiveDecryptFailures.containsKey(conversationId)) {
      return this;
    }
    final next = {...consecutiveDecryptFailures}..remove(conversationId);
    return ChatState(
      messagesByConversation: messagesByConversation,
      messageIdIndex: _messageIdIndex,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
      replyToMessage: replyToMessage,
      consecutiveDecryptFailures: next,
      signatureFailures: signatureFailures,
      groupsNeedingRotation: groupsNeedingRotation,
    );
  }

  /// Flag a conversation as needing a fresh group-key envelope. Triggered
  /// by a 410 Gone from `GET /api/groups/:id/keys/latest`.
  ChatState withGroupRotationNeeded(String conversationId) {
    if (groupsNeedingRotation.contains(conversationId)) {
      return this;
    }
    final next = {...groupsNeedingRotation, conversationId};
    return ChatState(
      messagesByConversation: messagesByConversation,
      messageIdIndex: _messageIdIndex,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
      replyToMessage: replyToMessage,
      consecutiveDecryptFailures: consecutiveDecryptFailures,
      signatureFailures: signatureFailures,
      groupsNeedingRotation: next,
    );
  }

  /// Clear the needs-rotation flag once a healthy envelope is fetched.
  ChatState withGroupRotationCleared(String conversationId) {
    if (!groupsNeedingRotation.contains(conversationId)) {
      return this;
    }
    final next = {...groupsNeedingRotation}..remove(conversationId);
    return ChatState(
      messagesByConversation: messagesByConversation,
      messageIdIndex: _messageIdIndex,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
      replyToMessage: replyToMessage,
      consecutiveDecryptFailures: consecutiveDecryptFailures,
      signatureFailures: signatureFailures,
      groupsNeedingRotation: next,
    );
  }

  /// Clear the signature-failure flag for a conversation. Called when
  /// the user explicitly dismisses the banner or when the group key
  /// rotates (because a fresh envelope invalidates the prior wedge).
  /// Audit Phase 4.
  ChatState withSignatureFailureCleared(String conversationId) {
    if (!signatureFailures.contains(conversationId)) {
      return this;
    }
    final next = {...signatureFailures}..remove(conversationId);
    return ChatState(
      messagesByConversation: messagesByConversation,
      messageIdIndex: _messageIdIndex,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
      replyToMessage: replyToMessage,
      consecutiveDecryptFailures: consecutiveDecryptFailures,
      signatureFailures: next,
      groupsNeedingRotation: groupsNeedingRotation,
    );
  }

  ChatState copyWith({
    Map<String, List<ChatMessage>>? messagesByConversation,
    Map<String, Set<String>>? messageIdIndex,
    Map<String, bool>? loadingHistory,
    Map<String, bool>? hasMore,
    ChatMessage? replyToMessage,
    bool clearReply = false,
    Map<String, int>? consecutiveDecryptFailures,
    Set<String>? signatureFailures,
    Set<String>? groupsNeedingRotation,
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
      consecutiveDecryptFailures:
          consecutiveDecryptFailures ?? this.consecutiveDecryptFailures,
      signatureFailures: signatureFailures ?? this.signatureFailures,
      groupsNeedingRotation:
          groupsNeedingRotation ?? this.groupsNeedingRotation,
    );
  }
}
