import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/chat_message.dart';
import '../../models/reaction.dart';
import '../../services/crypto_service.dart';
import '../../services/debug_log_service.dart';
import '../../services/group_crypto_service.dart';
import '../crypto_provider.dart'
    show cryptoProvider, cryptoServiceProvider, groupCryptoServiceProvider;
import '../../services/message_cache.dart';
import '../../utils/crypto_utils.dart';
import '../../utils/uuid_bytes.dart';
import '../auth_provider.dart';
import '../conversations_provider.dart';
import '../server_url_provider.dart';

part 'chat_provider.g.dart';
part 'chat_state.dart';
part 'chat_reactions.dart';
part 'chat_history.dart';
part 'chat_edits.dart';
part 'chat_recovery.dart';

/// Owns the per-conversation message list, the optimistic-send pipeline
/// (with 15s retry timers + reply-count bookkeeping), and the public API
/// the rest of the app reaches through `chatProvider`.
///
/// File layout (god-module split tracker #770):
/// - This file: notifier facade — timer map, `build`, hot-path send /
///   confirm / retry, status updates, reply state, `clear`.
/// - `chat_state.dart` (part): the immutable [ChatState] data class
///   plus placeholder-content constants and the `withMessage` /
///   `withSyncRestored` / `withSignatureFailureCleared` transitions.
/// - `chat_reactions.dart` (part): add/remove reaction.
/// - `chat_history.dart` (part): cache load, paginated REST fetch, 1:1
///   + group decrypt pipeline.
/// - `chat_edits.dart` (part): edits, soft-deletes, read sweeps, pin
///   toggles, forward helper.
/// - `chat_recovery.dart` (part): banner-driven recovery actions
///   (reset session, refresh group key, dismiss signature failure)
///   and the system-event injector.
@Riverpod(keepAlive: true)
class Chat extends _$Chat
    with
        ChatReactionsMixin,
        ChatHistoryMixin,
        ChatEditsMixin,
        ChatRecoveryMixin {
  /// Timers that transition pending messages to failed after 15 seconds
  /// without server confirmation.
  final Map<String, Timer> _sendTimeouts = {};

  @override
  ChatState build() {
    // Cancel any pending send-timeout timers when this notifier is
    // disposed (mirrors the legacy `dispose()` override).
    ref.onDispose(() {
      for (final timer in _sendTimeouts.values) {
        timer.cancel();
      }
      _sendTimeouts.clear();
    });

    // 410-Gone callback → groupsNeedingRotation flag → EncryptionStatusBanner.
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    void handler(String conversationId) {
      state = state.withGroupRotationNeeded(conversationId);
    }

    groupCrypto.onGroupNeedsRotation = handler;
    ref.onDispose(() {
      // Only detach if a later build hasn't installed its own handler.
      if (identical(groupCrypto.onGroupNeedsRotation, handler)) {
        groupCrypto.onGroupNeedsRotation = null;
      }
    });

    return const ChatState();
  }

  @override
  String get _serverUrl => ref.read(serverUrlProvider);

  /// (#919) Optimistic reply-count bump only when [bumpReplyCount] is true
  /// (live WS); historical seeders pass false to avoid double-counting.
  void addMessage(ChatMessage msg, {bool bumpReplyCount = true}) {
    // Dedup-by-id BEFORE withMessage so server echoes don't double-bump.
    final alreadyKnown =
        state._messageIdIndex[msg.conversationId]?.contains(msg.id) ?? false;

    var newState = state.withMessage(msg);
    if (bumpReplyCount && msg.replyToId != null && !alreadyKnown) {
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
    // Use real username for symmetry; "You" only as a last-resort fallback.
    final myName = ref.read(authProvider).username ?? 'You';
    final msg = ChatMessage(
      id: pendingId,
      fromUserId: myUserId,
      fromUsername: myName,
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
      // Atomic remove: skip if confirmSent() already cancelled it.
      final removed = _sendTimeouts.remove(pendingId);
      if (removed == null) return;
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

  /// Decrement the reply count on a parent message by 1 (floor at 0).
  ChatState _decrementReplyCount(
    ChatState s,
    String conversationId,
    String parentId,
  ) {
    final messages = s.messagesForConversation(conversationId);
    final idx = messages.indexWhere((m) => m.id == parentId);
    if (idx == -1) return s;
    final parent = messages[idx];
    if (parent.replyCount <= 0) return s;
    final updated = parent.copyWith(replyCount: parent.replyCount - 1);
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
      content: "Couldn't send · Tap to retry",
      failedContent: originalContent,
    );
    final updatedList = List<ChatMessage>.from(messages);
    updatedList[idx] = updated;
    var newState = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updatedList,
      },
    );
    // Roll back the optimistic replyCount bump on the parent so failed
    // sends don't permanently inflate the thread badge (#830).
    if (msg.replyToId != null) {
      newState = _decrementReplyCount(newState, conversationId, msg.replyToId!);
    }
    state = newState;
  }

  void confirmSent(
    String messageId,
    String conversationId,
    String timestamp, {
    String? channelId,
    DateTime? expiresAt,
  }) {
    // Replace pending ID with server ID so delivery receipts match.
    // Clone only the affected conv; other selectors stay reference-equal.
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

  /// Update message status (sent, delivered).
  void updateMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) {
    final messages = state.messagesByConversation[conversationId];
    if (messages == null) return;

    // (#830) Keep parent replyCount in sync on failed↔retried transitions.
    ChatMessage? before;
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx != -1) before = messages[idx];

    final updated = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(status: status);
      }
      return msg;
    }).toList();

    var newState = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: updated,
      },
    );

    if (before != null && before.replyToId != null) {
      final wasFailed = before.status == MessageStatus.failed;
      final isFailed = status == MessageStatus.failed;
      if (wasFailed && !isFailed) {
        newState = _incrementReplyCount(
          newState,
          conversationId,
          before.replyToId!,
        );
      } else if (!wasFailed && isFailed) {
        newState = _decrementReplyCount(
          newState,
          conversationId,
          before.replyToId!,
        );
      }
    }

    state = newState;
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

    // Full copy required for removal (spread can't express it); leave/clear
    // path is infrequent, cost acceptable.
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

  /// Reset all in-memory state.  Used on logout / account switch.
  /// (`build()`'s `ref.onDispose` already covers timer teardown when
  /// the provider itself is disposed; this method handles "stay
  /// alive but clear" semantics.)
  void clear() {
    for (final timer in _sendTimeouts.values) {
      timer.cancel();
    }
    _sendTimeouts.clear();
    state = const ChatState();
  }
}
