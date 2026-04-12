import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../services/debug_log_service.dart';
import '../services/notification_service.dart';
import '../utils/crypto_utils.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'privacy_provider.dart';
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

  /// Map raw exceptions to user-friendly error messages.
  String _friendlyError(Object error) {
    final msg = error.toString();
    if (msg.contains('SocketException') || msg.contains('Connection refused')) {
      return 'Unable to connect to server. Check your internet connection.';
    }
    if (msg.contains('TimeoutException')) {
      return 'Request timed out. Please try again.';
    }
    if (msg.contains('401') || msg.contains('Unauthorized')) {
      return 'Session expired. Please log in again.';
    }
    if (msg.contains('403') || msg.contains('Forbidden')) {
      return 'You don\'t have permission to do that.';
    }
    return 'Something went wrong. Please try again.';
  }

  /// Extract the `error` field from a JSON response body, or return [fallback].
  String _parseServerError(String body, String fallback) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        return data['error'] as String? ?? fallback;
      }
    } catch (_) {}
    return fallback;
  }

  Map<String, String> _headersWithToken(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  /// Compute total unread count and update the browser tab badge.
  void _updateTabBadge() {
    final total = state.conversations.fold<int>(
      0,
      (sum, c) => sum + c.unreadCount,
    );
    NotificationService().updateTabBadge(total);
  }

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
        _updateTabBadge();
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load conversations',
        );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
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

    final conversations = state.conversations;
    final index = conversations.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      final conv = conversations[index];
      final updatedConv = conv.copyWith(
        lastMessage: content,
        lastMessageTimestamp: timestamp,
        lastMessageSender: senderUsername,
        unreadCount: conv.unreadCount + 1,
      );

      // Build new list updating only the changed conversation and moving
      // it to the top, avoiding a full List.from() copy when possible.
      final updated = [
        updatedConv,
        for (var i = 0; i < conversations.length; i++)
          if (i != index) conversations[i],
      ];

      state = state.copyWith(conversations: updated);
      _updateTabBadge();
    } else {
      // New conversation we don't have locally -- reload from server
      loadConversations();
    }
  }

  /// Update the conversation preview if an edited message was the last one.
  void onMessageEdited({
    required String conversationId,
    required String newContent,
  }) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);
    if (index >= 0) {
      final conv = updated[index];
      // Only update preview -- we can't cheaply tell if this was the last
      // message, but updating the preview is harmless either way since the
      // next real message will overwrite it.
      updated[index] = conv.copyWith(lastMessage: newContent);
      _decryptedPreviews[conversationId] = newContent;
      state = state.copyWith(conversations: updated);
    }
  }

  /// Update the encryption flag for a conversation locally.
  void updateEncryption(String conversationId, bool isEncrypted) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);
    if (index >= 0) {
      updated[index] = updated[index].copyWith(isEncrypted: isEncrypted);
      // Clear cached plaintext preview so it doesn't leak after toggling
      // encryption on. The next message will repopulate the preview.
      _decryptedPreviews.remove(conversationId);
      state = state.copyWith(conversations: updated);
    }
  }

  /// Mark a conversation as read (reset unread count).
  void markAsRead(String conversationId) {
    final updated = List<Conversation>.from(state.conversations);
    final index = updated.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      updated[index] = updated[index].copyWith(unreadCount: 0);
      state = state.copyWith(conversations: updated);
      _updateTabBadge();
    }
  }

  /// Send read receipt to server.
  Future<void> sendReadReceipt(String conversationId) async {
    // Save old count so we can restore it if the server call fails.
    final oldCount =
        state.conversations
            .where((c) => c.id == conversationId)
            .firstOrNull
            ?.unreadCount ??
        0;

    markAsRead(conversationId);
    final privacy = ref.read(privacyProvider);
    if (!privacy.readReceiptsEnabled) {
      return;
    }
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
      // Rollback: restore the previous unread count so the badge reappears.
      if (oldCount > 0) {
        final rollback = List<Conversation>.from(state.conversations);
        final idx = rollback.indexWhere((c) => c.id == conversationId);
        if (idx >= 0) {
          rollback[idx] = rollback[idx].copyWith(unreadCount: oldCount);
          state = state.copyWith(conversations: rollback);
          _updateTabBadge();
        }
      }
    }
  }

  /// Find an existing DM with a peer, or create one by sending a greeting.
  ///
  /// Returns the conversation on success. Throws a [DmException] with a
  /// user-readable message when the server rejects the request (e.g.
  /// "Not a contact") or when a network error occurs.
  Future<Conversation> getOrCreateDm(
    String peerUserId,
    String peerUsername,
  ) async {
    // Search existing conversations for a non-group with that peer.
    // The server list is limited to 50 entries, so older/message-less DMs
    // might not be loaded yet -- we fall through to the API in that case.
    for (final conv in state.conversations) {
      if (!conv.isGroup) {
        final hasPeer = conv.members.any((m) => m.userId == peerUserId);
        if (hasPeer) return conv;
      }
    }

    // Not found -- create (or locate) the DM conversation via the server.
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

          // The server sorts conversations by last-message time (LIMIT 50).
          // A brand-new DM with no messages sorts last and may be excluded.
          // If it is not in the refreshed list, add a minimal entry so the
          // caller can navigate to it immediately; subsequent activity will
          // populate the full data.
          final found = state.conversations
              .where((c) => c.id == convId && !c.isGroup)
              .firstOrNull;
          if (found != null) return found;

          final newConv = Conversation(
            id: convId,
            isGroup: false,
            members: [
              ConversationMember(userId: peerUserId, username: peerUsername),
            ],
          );
          state = state.copyWith(
            conversations: [newConv, ...state.conversations],
          );
          DebugLogService.instance.log(
            LogLevel.info,
            'Conversations',
            'Created DM $convId with $peerUsername (not in top-50 list, added locally)',
          );
          return newConv;
        }
      } else {
        final errMsg = _parseServerError(
          response.body,
          'Could not start conversation',
        );
        DebugLogService.instance.log(
          LogLevel.error,
          'Conversations',
          'getOrCreateDm failed (HTTP ${response.statusCode}): $errMsg',
        );
        throw DmException(errMsg);
      }
    } on DmException {
      rethrow;
    } catch (e) {
      debugPrint('[Conversations] getOrCreateDm failed for $peerUserId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Conversations',
        'getOrCreateDm error for $peerUsername: $e',
      );
      throw DmException(_friendlyError(e));
    }

    // Unreachable: all paths either return a Conversation or throw.
    throw const DmException('Could not start conversation');
  }

  /// Toggle mute state for a conversation.
  /// Leave/delete a conversation. Removes the user's membership so it
  /// disappears from their conversation list. Messages are not deleted.
  Future<bool> leaveConversation(String conversationId) async {
    try {
      final response = await _authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/conversations/$conversationId/leave'),
          headers: _headersWithToken(token),
        ),
      );
      if (response.statusCode == 200) {
        final updated = state.conversations
            .where((c) => c.id != conversationId)
            .toList();
        state = state.copyWith(conversations: updated);
        // Clear cached messages so stale data doesn't linger in memory.
        ref.read(chatProvider.notifier).clearConversation(conversationId);
        return true;
      }
    } catch (e) {
      debugPrint('[Conversations] leaveConversation failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Conversations',
        'leaveConversation error: $e',
      );
    }
    return false;
  }

  Future<void> toggleMute(String conversationId) async {
    final index = state.conversations.indexWhere((c) => c.id == conversationId);
    if (index < 0) return;

    final conv = state.conversations[index];
    final newMuted = !conv.isMuted;

    // Optimistically update local state
    final updated = List<Conversation>.from(state.conversations);
    updated[index] = conv.copyWith(isMuted: newMuted);
    state = state.copyWith(conversations: updated);

    try {
      await _authenticatedRequest(
        (token) => http.put(
          Uri.parse('$_serverUrl/api/conversations/$conversationId/mute'),
          headers: _headersWithToken(token),
          body: jsonEncode({'is_muted': newMuted}),
        ),
      );
    } catch (e) {
      // Revert on failure
      final reverted = List<Conversation>.from(state.conversations);
      final idx = reverted.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        reverted[idx] = reverted[idx].copyWith(isMuted: !newMuted);
        state = state.copyWith(conversations: reverted);
      }
      debugPrint('[Conversations] toggleMute failed for $conversationId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Conversations',
        'toggleMute error for $conversationId: $e',
      );
    }
  }

  /// Leave a group conversation and remove it from local state.
  /// Returns true on success, false on failure.
  Future<bool> leaveGroup(String groupId) async {
    try {
      final response = await _authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/groups/$groupId/leave'),
          headers: _headersWithToken(token),
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        final updated = state.conversations
            .where((c) => c.id != groupId)
            .toList();
        state = state.copyWith(conversations: updated);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[Conversations] leaveGroup failed for $groupId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Conversations',
        'leaveGroup error for $groupId: $e',
      );
      return false;
    }
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
      state = state.copyWith(error: _friendlyError(e));
      return null;
    }
  }
}

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, ConversationsState>((ref) {
      return ConversationsNotifier(ref);
    });

/// Thrown by [ConversationsNotifier.getOrCreateDm] when the server rejects
/// the request or a network error occurs. [message] is safe to display to
/// the user.
class DmException implements Exception {
  final String message;
  const DmException(this.message);

  @override
  String toString() => message;
}
