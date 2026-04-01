import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../utils/crypto_utils.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';

class ConversationsState {
  final List<Conversation> conversations;
  final bool isLoading;
  final String? error;

  const ConversationsState({
    this.conversations = const [],
    this.isLoading = false,
    this.error,
  });

  ConversationsState copyWith({
    List<Conversation>? conversations,
    bool? isLoading,
    String? error,
  }) {
    return ConversationsState(
      conversations: conversations ?? this.conversations,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class ConversationsNotifier extends StateNotifier<ConversationsState> {
  final Ref ref;

  /// Cache of decrypted message previews by conversationId.
  final Map<String, String> _decryptedPreviews = {};

  ConversationsNotifier(this.ref) : super(const ConversationsState());

  String get _serverUrl => ref.read(serverUrlProvider);

  Map<String, String> _headersWithToken(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  /// Make an authenticated request with automatic 401 refresh-and-retry.
  Future<http.Response> _authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) async {
    return ref.read(authProvider.notifier).authenticatedRequest(requestFn);
  }

  /// Load all conversations from the server.
  Future<void> loadConversations() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/conversations'),
          headers: _headersWithToken(token),
        ),
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final List<dynamic> list = body is List
            ? body
            : (body['conversations'] as List? ?? []);
        final conversations = list
            .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
            .toList();

        // Replace encrypted previews with cached decrypted text or placeholder
        for (var i = 0; i < conversations.length; i++) {
          final conv = conversations[i];
          if (conv.lastMessage != null && looksEncrypted(conv.lastMessage!)) {
            final cached = _decryptedPreviews[conv.id];
            conversations[i] = conv.copyWith(
              lastMessage: cached ?? 'Encrypted message',
            );
          }
        }

        // Sort by last activity (most recent first)
        conversations.sort((a, b) {
          final aTime = a.lastMessageTimestamp ?? '';
          final bTime = b.lastMessageTimestamp ?? '';
          return bTime.compareTo(aTime);
        });

        state = state.copyWith(conversations: conversations, isLoading: false);
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load conversations',
        );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Update a conversation when a new message is received.
  void onNewMessage({
    required String conversationId,
    required String content,
    required String timestamp,
    required String senderUsername,
  }) {
    // Cache the decrypted preview (content passed here is already decrypted
    // by the websocket provider)
    _decryptedPreviews[conversationId] = content;

    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      final conv = updated[index];
      updated[index] = conv.copyWith(
        lastMessage: content,
        lastMessageTimestamp: timestamp,
        lastMessageSender: senderUsername,
        unreadCount: conv.unreadCount + 1,
      );

      // Re-sort by last activity
      updated.sort((a, b) {
        final aTime = a.lastMessageTimestamp ?? '';
        final bTime = b.lastMessageTimestamp ?? '';
        return bTime.compareTo(aTime);
      });

      state = state.copyWith(conversations: updated);
    } else {
      // New conversation we don't have locally -- reload from server
      loadConversations();
    }
  }

  /// Mark a conversation as read (reset unread count).
  void markAsRead(String conversationId) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      updated[index] = updated[index].copyWith(unreadCount: 0);
      state = state.copyWith(conversations: updated);
    }
  }

  /// Send read receipt to server.
  Future<void> sendReadReceipt(String conversationId) async {
    markAsRead(conversationId);
    try {
      await _authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/conversations/$conversationId/read'),
          headers: _headersWithToken(token),
        ),
      );
    } catch (e) {
      debugPrint(
        '[Conversations] sendReadReceipt failed for '
        '$conversationId: $e',
      );
    }
  }

  /// Find an existing DM with a peer, or create one by sending a greeting.
  Future<Conversation?> getOrCreateDm(
    String peerUserId,
    String peerUsername,
  ) async {
    // Search existing conversations for a non-group with that peer
    for (final conv in state.conversations) {
      if (!conv.isGroup) {
        final hasPeer = conv.members.any((m) => m.userId == peerUserId);
        if (hasPeer) return conv;
      }
    }

    // Not found -- create a new DM conversation via the server endpoint.
    try {
      final response = await _authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/conversations/dm'),
          headers: _headersWithToken(token),
          body: jsonEncode({'peer_user_id': peerUserId}),
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final convId = data['conversation_id'] as String?;
        if (convId != null && convId.isNotEmpty) {
          await loadConversations();
          return state.conversations.where((c) => c.id == convId).firstOrNull;
        }
      }
    } catch (_) {
      // Fall through
    }

    return null;
  }

  /// Create a new group conversation.
  Future<String?> createGroup(
    String name,
    List<String> memberIds, {
    String? description,
    bool isPublic = false,
  }) async {
    try {
      final body = <String, dynamic>{
        'name': name,
        'member_ids': memberIds,
        'is_public': isPublic,
      };
      if (description != null) {
        body['description'] = description;
      }
      final response = await _authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/groups'),
          headers: _headersWithToken(token),
          body: jsonEncode(body),
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final conversationId =
            data['conversation_id'] as String? ?? data['id'] as String? ?? '';
        await loadConversations();
        return conversationId;
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          error: data['error'] as String? ?? 'Failed to create group',
        );
        return null;
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }
}

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, ConversationsState>((ref) {
      return ConversationsNotifier(ref);
    });
