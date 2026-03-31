import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../services/crypto_service.dart';

class ChatState {
  /// Messages keyed by conversation ID.
  final Map<String, List<ChatMessage>> messagesByConversation;

  /// Legacy: messages keyed by peer user ID (for backward compat).
  final Map<String, List<ChatMessage>> messagesByPeer;

  /// Whether history is currently loading for a conversation.
  final Map<String, bool> loadingHistory;

  /// Whether there are more messages to load (for pagination).
  final Map<String, bool> hasMore;

  const ChatState({
    this.messagesByConversation = const {},
    this.messagesByPeer = const {},
    this.loadingHistory = const {},
    this.hasMore = const {},
  });

  /// Get messages for a conversation ID.
  List<ChatMessage> messagesForConversation(String conversationId) {
    return messagesByConversation[conversationId] ?? [];
  }

  /// Get messages for a peer user ID (legacy support).
  List<ChatMessage> messagesFor(String peerUserId) {
    return messagesByPeer[peerUserId] ?? [];
  }

  bool isLoadingHistory(String conversationId) {
    return loadingHistory[conversationId] ?? false;
  }

  bool conversationHasMore(String conversationId) {
    return hasMore[conversationId] ?? true;
  }

  ChatState withMessage(String peerKey, ChatMessage msg) {
    final updatedPeer = Map<String, List<ChatMessage>>.from(messagesByPeer);
    updatedPeer[peerKey] = [...(updatedPeer[peerKey] ?? []), msg];

    final updatedConv =
        Map<String, List<ChatMessage>>.from(messagesByConversation);
    if (msg.conversationId.isNotEmpty) {
      final existing = updatedConv[msg.conversationId] ?? [];
      // Deduplicate by ID
      if (!existing.any((m) => m.id == msg.id)) {
        updatedConv[msg.conversationId] = [...existing, msg];
      }
    }

    return ChatState(
      messagesByConversation: updatedConv,
      messagesByPeer: updatedPeer,
      loadingHistory: loadingHistory,
      hasMore: hasMore,
    );
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier() : super(const ChatState());

  static const String _serverUrl = 'http://localhost:8080';

  void addMessage(ChatMessage msg) {
    final peerKey = msg.isMine
        ? _findPeerForConversation(msg.conversationId) ?? msg.fromUserId
        : msg.fromUserId;
    state = state.withMessage(peerKey, msg);
  }

  void addOptimistic(String peerUserId, String content, String myUserId,
      {String conversationId = ''}) {
    final msg = ChatMessage(
      id: 'pending_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: myUserId,
      fromUsername: 'You',
      conversationId: conversationId,
      content: content,
      timestamp: DateTime.now().toIso8601String(),
      isMine: true,
      status: MessageStatus.sending,
    );
    state = state.withMessage(peerUserId, msg);
  }

  void confirmSent(String messageId, String conversationId, String timestamp) {
    // Update optimistic messages with real data if needed.
    // For now, optimistic messages are already displayed.
  }

  /// Load message history from the server for a conversation.
  Future<void> loadHistory(String conversationId, String token,
      {String? before}) async {
    if (state.isLoadingHistory(conversationId)) return;

    final updatedLoading = Map<String, bool>.from(state.loadingHistory);
    updatedLoading[conversationId] = true;
    state = ChatState(
      messagesByConversation: state.messagesByConversation,
      messagesByPeer: state.messagesByPeer,
      loadingHistory: updatedLoading,
      hasMore: state.hasMore,
    );

    try {
      var url = '$_serverUrl/api/messages/$conversationId?limit=50';
      if (before != null) {
        url += '&before=$before';
      }

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final List<dynamic> messagesList =
            body is List ? body : (body['messages'] as List? ?? []);

        // We need the user ID to determine isMine. Extract from token or
        // pass it in. For now, we parse from the existing messages or use
        // a placeholder approach -- the caller should set myUserId.
        // We'll accept it as a parameter via an overload.
        _mergeHistory(conversationId, messagesList, before != null);
      }
    } catch (_) {
      // Silently fail -- messages stay as-is
    } finally {
      final updatedLoading2 = Map<String, bool>.from(state.loadingHistory);
      updatedLoading2[conversationId] = false;
      state = ChatState(
        messagesByConversation: state.messagesByConversation,
        messagesByPeer: state.messagesByPeer,
        loadingHistory: updatedLoading2,
        hasMore: state.hasMore,
      );
    }
  }

  /// Check if a string looks like base64-encoded ciphertext.
  static bool _looksEncrypted(String text) {
    if (text.length < 20) return false;
    return RegExp(r'^[A-Za-z0-9+/=]{20,}$').hasMatch(text);
  }

  /// Load history with the user's own ID for isMine determination.
  /// If [crypto] is provided, attempts to decrypt encrypted messages.
  Future<void> loadHistoryWithUserId(
    String conversationId,
    String token,
    String myUserId, {
    String? before,
    CryptoService? crypto,
  }) async {
    if (state.isLoadingHistory(conversationId)) return;

    final updatedLoading = Map<String, bool>.from(state.loadingHistory);
    updatedLoading[conversationId] = true;
    state = ChatState(
      messagesByConversation: state.messagesByConversation,
      messagesByPeer: state.messagesByPeer,
      loadingHistory: updatedLoading,
      hasMore: state.hasMore,
    );

    try {
      var url = '$_serverUrl/api/messages/$conversationId?limit=50';
      if (before != null) {
        url += '&before=${Uri.encodeComponent(before)}';
      }

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final List<dynamic> messagesList =
            body is List ? body : (body['messages'] as List? ?? []);

        final newMessages = <ChatMessage>[];
        for (final e in messagesList) {
          var msg = ChatMessage.fromServerJson(
              e as Map<String, dynamic>, myUserId);

          // Attempt to decrypt encrypted history messages
          if (_looksEncrypted(msg.content)) {
            if (crypto != null) {
              try {
                final decrypted = await crypto.decryptMessage(
                    msg.fromUserId, msg.content);
                msg = msg.copyWith(content: decrypted);
              } catch (_) {
                msg = msg.copyWith(content: '[Encrypted history]');
              }
            } else {
              msg = msg.copyWith(content: '[Encrypted history]');
            }
          }

          newMessages.add(msg);
        }

        _mergeMessages(conversationId, newMessages, before != null);
      }
    } catch (_) {
      // Silently fail
    } finally {
      final updatedLoading2 = Map<String, bool>.from(state.loadingHistory);
      updatedLoading2[conversationId] = false;
      state = ChatState(
        messagesByConversation: state.messagesByConversation,
        messagesByPeer: state.messagesByPeer,
        loadingHistory: updatedLoading2,
        hasMore: state.hasMore,
      );
    }
  }

  void _mergeHistory(
      String conversationId, List<dynamic> serverMessages, bool isPagination) {
    // Without myUserId, we cannot properly set isMine. This method is a
    // fallback; prefer loadHistoryWithUserId.
  }

  void _mergeMessages(
      String conversationId, List<ChatMessage> newMessages, bool isPagination) {
    final updatedConv =
        Map<String, List<ChatMessage>>.from(state.messagesByConversation);
    final existing = updatedConv[conversationId] ?? [];
    final existingIds = existing.map((m) => m.id).toSet();

    final deduped =
        newMessages.where((m) => !existingIds.contains(m.id)).toList();

    if (isPagination) {
      // Older messages go to the front
      updatedConv[conversationId] = [...deduped, ...existing];
    } else {
      // Initial load: server messages first, then any in-memory ones
      updatedConv[conversationId] = [...deduped, ...existing];
    }

    final updatedHasMore = Map<String, bool>.from(state.hasMore);
    updatedHasMore[conversationId] = newMessages.length >= 50;

    state = ChatState(
      messagesByConversation: updatedConv,
      messagesByPeer: state.messagesByPeer,
      loadingHistory: state.loadingHistory,
      hasMore: updatedHasMore,
    );
  }

  /// Add a reaction to a message.
  void addReaction(String conversationId, Reaction reaction) {
    final updatedConv =
        Map<String, List<ChatMessage>>.from(state.messagesByConversation);
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages.map((msg) {
      if (msg.id == reaction.messageId) {
        final reactions = List<Reaction>.from(msg.reactions);
        // Remove existing reaction from same user with same emoji (toggle)
        reactions.removeWhere(
            (r) => r.userId == reaction.userId && r.emoji == reaction.emoji);
        reactions.add(reaction);
        return msg.copyWith(reactions: reactions);
      }
      return msg;
    }).toList();

    state = ChatState(
      messagesByConversation: updatedConv,
      messagesByPeer: state.messagesByPeer,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Remove a reaction from a message.
  void removeReaction(
      String conversationId, String messageId, String userId, String emoji) {
    final updatedConv =
        Map<String, List<ChatMessage>>.from(state.messagesByConversation);
    final messages = updatedConv[conversationId];
    if (messages == null) return;

    updatedConv[conversationId] = messages.map((msg) {
      if (msg.id == messageId) {
        final reactions = List<Reaction>.from(msg.reactions);
        reactions
            .removeWhere((r) => r.userId == userId && r.emoji == emoji);
        return msg.copyWith(reactions: reactions);
      }
      return msg;
    }).toList();

    state = ChatState(
      messagesByConversation: updatedConv,
      messagesByPeer: state.messagesByPeer,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  /// Update message status (sent, delivered).
  void updateMessageStatus(
      String conversationId, String messageId, MessageStatus status) {
    final updatedConv =
        Map<String, List<ChatMessage>>.from(state.messagesByConversation);
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
      messagesByPeer: state.messagesByPeer,
      loadingHistory: state.loadingHistory,
      hasMore: state.hasMore,
    );
  }

  String? _findPeerForConversation(String conversationId) {
    // For now, we don't track this mapping.
    return null;
  }

  void clear() {
    state = const ChatState();
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier();
});
