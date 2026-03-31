import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import 'auth_provider.dart';

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

  ConversationsNotifier(this.ref) : super(const ConversationsState());

  String get _serverUrl => 'http://localhost:8080';
  String? get _token => ref.read(authProvider).token;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_token ?? ""}',
      };

  /// Load all conversations from the server.
  Future<void> loadConversations() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/api/conversations'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final List<dynamic> list = body is List ? body : (body['conversations'] as List? ?? []);
        final conversations = list
            .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
            .toList();

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
      await http.post(
        Uri.parse('$_serverUrl/api/conversations/$conversationId/read'),
        headers: _headers,
      );
    } catch (_) {
      // Best effort
    }
  }

  /// Create a new group conversation.
  Future<String?> createGroup(String name, List<String> memberIds) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/groups'),
        headers: _headers,
        body: jsonEncode({
          'name': name,
          'member_ids': memberIds,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final conversationId = data['conversation_id'] as String? ??
            data['id'] as String? ??
            '';
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
