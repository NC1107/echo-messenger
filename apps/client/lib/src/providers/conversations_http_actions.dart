part of 'conversations_provider.dart';

// ---------------------------------------------------------------------------
// HTTP action methods for ConversationsNotifier.
//
// Extracted from conversations_provider.dart (#712). These methods perform
// REST API calls and manage local state for CRUD operations.
// ---------------------------------------------------------------------------

mixin _ConversationsHttpActionsMixin on StateNotifier<ConversationsState> {
  // Dependencies implemented by ConversationsNotifier.
  Ref get ref;
  String get _serverUrl;
  Future<void> loadConversations();
  Future<http.Response> _authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  );
  Map<String, String> _headersWithToken(String token);
  String _friendlyError(Object error);
  String _parseServerError(String body, String fallback);

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

  /// Toggle mute state for a conversation.
  Future<bool> toggleMute(String conversationId) async {
    final conv = state.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    if (conv == null) return false;
    return setMuted(conversationId, !conv.isMuted);
  }

  /// Set the explicit mute state for a conversation. Optimistically updates
  /// local state, then PUTs `/api/conversations/:id/mute`. Returns true on
  /// success; on failure the optimistic update is reverted and false is
  /// returned so the caller can surface a toast.
  Future<bool> setMuted(String conversationId, bool isMuted) async {
    final index = state.conversations.indexWhere((c) => c.id == conversationId);
    if (index < 0) return false;

    final conv = state.conversations[index];
    if (conv.isMuted == isMuted) return true; // no-op success
    final previousMuted = conv.isMuted;

    // Optimistically update local state.
    final updated = List<Conversation>.from(state.conversations);
    updated[index] = conv.copyWith(isMuted: isMuted);
    state = state.copyWith(conversations: updated);

    bool success = false;
    try {
      final response = await _authenticatedRequest(
        (token) => http.put(
          Uri.parse('$_serverUrl/api/conversations/$conversationId/mute'),
          headers: _headersWithToken(token),
          body: jsonEncode({'is_muted': isMuted}),
        ),
      );
      success = response.statusCode == 200;
      if (!success) {
        debugPrint(
          '[Conversations] setMuted got HTTP ${response.statusCode} '
          'for $conversationId',
        );
      }
    } catch (e) {
      debugPrint('[Conversations] setMuted failed for $conversationId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Conversations',
        'setMuted error for $conversationId: $e',
      );
    }

    if (!success) {
      // Revert the optimistic update.
      final reverted = List<Conversation>.from(state.conversations);
      final idx = reverted.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        reverted[idx] = reverted[idx].copyWith(isMuted: previousMuted);
        state = state.copyWith(conversations: reverted);
      }
    }
    return success;
  }

  /// Toggle pin state for a conversation, syncing with the server.
  /// Returns true on success. On failure the optimistic update is reverted.
  Future<bool> setPinned(String conversationId, bool pinned) async {
    final index = state.conversations.indexWhere((c) => c.id == conversationId);
    if (index < 0) return false;

    final conv = state.conversations[index];
    if (conv.isPinned == pinned) return true;
    final previousPinned = conv.isPinned;

    final updated = List<Conversation>.from(state.conversations);
    updated[index] = conv.copyWith(isPinned: pinned);
    state = state.copyWith(conversations: updated);

    bool success = false;
    try {
      final response = await _authenticatedRequest(
        (token) => pinned
            ? http.put(
                Uri.parse('$_serverUrl/api/conversations/$conversationId/pin'),
                headers: _headersWithToken(token),
              )
            : http.delete(
                Uri.parse('$_serverUrl/api/conversations/$conversationId/pin'),
                headers: _headersWithToken(token),
              ),
      );
      success = response.statusCode == 204 || response.statusCode == 200;
      if (!success) {
        debugPrint(
          '[Conversations] setPinned got HTTP ${response.statusCode} '
          'for $conversationId',
        );
      }
    } catch (e) {
      debugPrint('[Conversations] setPinned failed for $conversationId: $e');
    }

    if (!success) {
      final reverted = List<Conversation>.from(state.conversations);
      final idx = reverted.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        reverted[idx] = reverted[idx].copyWith(isPinned: previousPinned);
        state = state.copyWith(conversations: reverted);
      }
    }
    return success;
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
