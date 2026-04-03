import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../services/crypto_service.dart';
import '../utils/crypto_utils.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';

class ChatState {
  /// Messages keyed by conversation ID.
  final Map<String, List<ChatMessage>> messagesByConversation;

  /// Whether history is currently loading for a conversation.
  /// Key format: conversationId:channelId (channelId empty for full conversation).
  final Map<String, bool> loadingHistory;

  /// Whether there are more messages to load (for pagination).
  /// Key format: conversationId:channelId (channelId empty for full conversation).
  final Map<String, bool> hasMore;

  const ChatState({
    this.messagesByConversation = const {},
    this.loadingHistory = const {},
    this.hasMore = const {},
  });

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
    final updatedConv = Map<String, List<ChatMessage>>.from(
      messagesByConversation,
    );
    if (msg.conversationId.isNotEmpty) {
      final existing = updatedConv[msg.conversationId] ?? [];
      // Deduplicate by ID
      if (!existing.any((m) => m.id == msg.id)) {
        updatedConv[msg.conversationId] = [...existing, msg];
      }
    }

    return ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
    );
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  final Ref ref;

  ChatNotifier(this.ref) : super(const ChatState());

  String get _serverUrl => ref.read(serverUrlProvider);

  void addMessage(ChatMessage msg) {
    state = state.withMessage(msg);
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
  }) {
    final msg = ChatMessage(
      id: 'pending_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: myUserId,
      fromUsername: 'You',
      conversationId: conversationId,
      channelId: channelId,
      content: content,
      timestamp: DateTime.now().toIso8601String(),
      isMine: true,
      status: MessageStatus.sending,
    );
    state = state.withMessage(msg);
  }

  void confirmSent(
    String messageId,
    String conversationId,
    String timestamp, {
    String? channelId,
  }) {
    // Replace the most recent pending/sending message in this conversation
    // with the server-assigned ID so that delivery receipts can match it.
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final messages = updatedConv[conversationId];
    if (messages != null) {
      // Find the most recent optimistic (pending_*) message from us
      for (var i = messages.length - 1; i >= 0; i--) {
        final msg = messages[i];
        if (msg.id.startsWith('pending_') &&
            msg.isMine &&
            msg.status == MessageStatus.sending &&
            (channelId == null || msg.channelId == channelId)) {
          final updatedMessages = List<ChatMessage>.from(messages);
          updatedMessages[i] = msg.copyWith(
            id: messageId,
            timestamp: timestamp,
            status: MessageStatus.sent,
            channelId: channelId ?? msg.channelId,
          );
          updatedConv[conversationId] = updatedMessages;
          break;
        }
      }
    }

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Load history with the user's own ID for isMine determination.
  /// If [crypto] is provided, attempts to decrypt encrypted messages.
  /// Set [isGroup] to true to skip decryption (group messages are plaintext).
  Future<void> loadHistoryWithUserId(
    String conversationId,
    String token,
    String myUserId, {
    String? channelId,
    String? before,
    CryptoService? crypto,
    bool isGroup = false,
  }) async {
    final historyKey = '$conversationId:${channelId ?? ''}';
    if (state.isLoadingHistory(conversationId, channelId: channelId)) return;

    final updatedLoading = Map<String, bool>.from(state.loadingHistory);
    updatedLoading[historyKey] = true;
    state = ChatState(
      messagesByConversation: state.messagesByConversation,
      loadingHistory: updatedLoading,
      hasMore: state.hasMore,
    );

    try {
      var url = '$_serverUrl/api/messages/$conversationId?limit=50';
      if (channelId != null && channelId.isNotEmpty) {
        url += '&channel_id=${Uri.encodeComponent(channelId)}';
      }
      if (before != null) {
        url += '&before=${Uri.encodeComponent(before)}';
      }

      final response = await ref
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

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final List<dynamic> messagesList = body is List
            ? body
            : (body['messages'] as List? ?? []);

        final newMessages = <ChatMessage>[];
        for (final e in messagesList) {
          var msg = ChatMessage.fromServerJson(
            e as Map<String, dynamic>,
            myUserId,
          );

          // Attempt to decrypt encrypted history messages (skip for groups
          // since group messages are sent as plaintext).
          if (!isGroup && looksEncrypted(msg.content)) {
            if (crypto != null) {
              try {
                final decrypted = await crypto.decryptMessage(
                  msg.fromUserId,
                  msg.content,
                );
                msg = msg.copyWith(content: decrypted, isEncrypted: true);
              } catch (e) {
                // History messages are immutable artifacts -- don't
                // invalidate the live session for a past message.
                debugPrint('[Chat] History decrypt failed for ${msg.id}: $e');
                msg = msg.copyWith(
                  content: '[Could not decrypt]',
                  isEncrypted: true,
                );
              }
            } else {
              msg = msg.copyWith(
                content: '[Encrypted history]',
                isEncrypted: true,
              );
            }
          }

          newMessages.add(msg);
        }

        _mergeMessages(conversationId, newMessages, channelId: channelId);
      }
    } catch (e) {
      debugPrint(
        '[Chat] loadHistoryWithUserId failed for '
        '$conversationId: $e',
      );
    } finally {
      final updatedLoading2 = Map<String, bool>.from(state.loadingHistory);
      updatedLoading2[historyKey] = false;
      state = ChatState(
        messagesByConversation: state.messagesByConversation,
        loadingHistory: updatedLoading2,
        hasMore: state.hasMore,
      );
    }
  }

  void _mergeMessages(
    String conversationId,
    List<ChatMessage> newMessages, {
    String? channelId,
  }) {
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final existing = updatedConv[conversationId] ?? [];
    final existingIds = existing.map((m) => m.id).toSet();

    final deduped = newMessages
        .where((m) => !existingIds.contains(m.id))
        .toList();

    updatedConv[conversationId] = [...deduped, ...existing]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final updatedHasMore = Map<String, bool>.from(state.hasMore);
    updatedHasMore['$conversationId:${channelId ?? ''}'] =
        newMessages.length >= 50;

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: updatedHasMore,
    );
  }

  /// Add a reaction to a message.
  void addReaction(String conversationId, Reaction reaction) {
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages.map((msg) {
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

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Remove a reaction from a message.
  void removeReaction(
    String conversationId,
    String messageId,
    String userId,
    String emoji,
  ) {
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages.map((msg) {
      if (msg.id == messageId) {
        final reactions = List<Reaction>.from(msg.reactions);
        reactions.removeWhere((r) => r.userId == userId && r.emoji == emoji);
        return msg.copyWith(reactions: reactions);
      }
      return msg;
    }).toList();

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Update message status (sent, delivered).
  void updateMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) {
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(status: status);
      }
      return msg;
    }).toList();

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Mark all of my sent/delivered messages in a conversation as read.
  void markConversationRead(String conversationId) {
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages.map((msg) {
      if (msg.isMine &&
          (msg.status == MessageStatus.sent ||
              msg.status == MessageStatus.delivered)) {
        return msg.copyWith(status: MessageStatus.read);
      }
      return msg;
    }).toList();

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Delete a message from local state.
  void deleteMessage(String conversationId, String messageId) {
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages
        .where((msg) => msg.id != messageId)
        .toList();

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Update a message's content and set editedAt.
  void editMessage(
    String conversationId,
    String messageId,
    String newContent, {
    String? editedAt,
  }) {
    final updatedConv = Map<String, List<ChatMessage>>.from(
      state.messagesByConversation,
    );
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages.map((msg) {
      if (msg.id == messageId) {
        return msg.copyWith(
          content: newContent,
          editedAt: editedAt ?? DateTime.now().toIso8601String(),
        );
      }
      return msg;
    }).toList();

    state = ChatState(
      messagesByConversation: updatedConv,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  void clear() {
    state = const ChatState();
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(ref);
});
