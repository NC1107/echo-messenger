part of '../ws_message_handler.dart';

extension PresenceHandlersOn on WsMessageHandler {
  void _handlePresence(Map<String, dynamic> json) {
    final userId = json['user_id'] as String? ?? '';
    final status = json['status'] as String? ?? '';
    // presence_status is the raw stored value (may differ from status when
    // broadcast_status is "offline" due to invisible setting).
    final presenceStatus = json['presence_status'] as String? ?? status;
    if (userId.isEmpty) return;

    final updatedOnline = Set<String>.from(_state.onlineUsers);
    final updatedStatuses = Map<String, String>.from(_state.presenceStatuses);
    final updatedLastSeen = Map<String, DateTime>.from(_state.lastSeenAt);

    if (status == 'offline') {
      updatedOnline.remove(userId);
      updatedStatuses.remove(userId);
      // Stamp last_seen_at so the chat header can render "last seen <ago>"
      // for this peer (#503). Server provides RFC3339; fall back to now if
      // the field is absent (older server).
      final raw = json['last_seen_at'] as String?;
      final ts = raw != null ? DateTime.tryParse(raw) : null;
      updatedLastSeen[userId] = ts ?? DateTime.now().toUtc();
    } else {
      updatedOnline.add(userId);
      updatedStatuses[userId] = presenceStatus;
      // Don't clear lastSeenAt — preserve the previous value so a brief
      // online flash doesn't lose the historical timestamp on next offline.
    }
    _state = _state.copyWith(
      onlineUsers: updatedOnline,
      presenceStatuses: updatedStatuses,
      lastSeenAt: updatedLastSeen,
    );
  }

  /// Replace the local online-set from a server-sent `presence_list` snapshot.
  ///
  /// The server emits this event right after a WS connect so the client can
  /// reconcile stale presence state in one shot (#436).
  ///
  /// Supports two payload shapes:
  ///   • object list: `[{"user_id":"…","status":"…"}, …]`  (new format, post-#436)
  ///   • string list: `["uuid1", "uuid2", …]`              (legacy, treat all as "online")
  void _handlePresenceList(Map<String, dynamic> json) {
    final rawUsers = json['users'] as List? ?? [];
    final newOnline = <String>{};
    final newStatuses = <String, String>{};

    for (final entry in rawUsers) {
      if (entry is String) {
        // Legacy format: plain ID list.
        newOnline.add(entry);
        newStatuses[entry] = 'online';
      } else if (entry is Map<String, dynamic>) {
        final userId = entry['user_id'] as String? ?? '';
        final status = entry['status'] as String? ?? 'online';
        if (userId.isEmpty) continue;
        newOnline.add(userId);
        newStatuses[userId] = status;
      }
    }

    _state = _state.copyWith(
      onlineUsers: newOnline,
      presenceStatuses: newStatuses,
    );
  }

  /// #660 — Insert the newly-joined member into the local conversations state
  /// so the members panel refreshes in real time without a manual reload.
  ///
  /// For encrypted groups, also auto-rotate the group key so the new member
  /// gets an envelope wrapped for their identity key. Without this, a public
  /// encrypted group is unusable for any joiner — they have no key to
  /// decrypt incoming messages or encrypt outgoing ones, and the existing
  /// banner-based recovery only fires after 3 decrypt failures on the
  /// joiner's side (which they can't trigger because they can't even send).
  /// Only admins/owners run the rotation; everyone else just updates their
  /// local member list and waits for the rotated key to arrive over WS.
  void _handleMemberAdded(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String? ?? '';
    final userId = json['user_id'] as String? ?? '';
    final username = json['username'] as String? ?? '';
    if (conversationId.isEmpty || userId.isEmpty || username.isEmpty) return;

    final member = ConversationMember(
      userId: userId,
      username: username,
      role: json['role'] as String? ?? 'member',
      avatarUrl: json['avatar_url'] as String?,
    );

    // When the local user is the one being added (e.g. someone invited them
    // to a brand new group, or they joined via invite link), the
    // conversation is almost certainly not in local state yet —
    // `addGroupMember` silently no-ops on unknown conversations, so the
    // sidebar would stay stale until a hard refresh. Trigger a full
    // conversations reload so the new group appears in the list right
    // away. Other members of an existing group still hit the cheaper
    // in-place `addGroupMember` path.
    final myUserId = ref.read(authProvider).userId ?? '';
    final convs = ref.read(conversationsProvider).conversations;
    final isKnownConv = convs.any((c) => c.id == conversationId);
    if (userId == myUserId && !isKnownConv) {
      ref.read(conversationsProvider.notifier).loadConversations();
    } else {
      ref
          .read(conversationsProvider.notifier)
          .addGroupMember(conversationId, member);
    }

    _maybeRotateOnJoin(conversationId, userId);
  }

  /// Rotate the group key when a new member joins an encrypted group, if
  /// the current user is admin/owner. The rotation includes the new member
  /// in the recipient list so their first decrypt works.
  void _maybeRotateOnJoin(String conversationId, String newMemberId) {
    final myUserId = ref.read(authProvider).userId ?? '';
    if (myUserId.isEmpty || myUserId == newMemberId) return;

    final conv = ref
        .read(conversationsProvider)
        .conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    if (conv == null || !conv.isEncrypted) return;

    final myMember = conv.members
        .where((m) => m.userId == myUserId)
        .firstOrNull;
    final isAdminOrOwner =
        myMember?.role == 'owner' || myMember?.role == 'admin';
    if (!isAdminOrOwner) return;

    debugLog(
      'Encrypted group $conversationId got new member — rotating key',
      'WebSocket',
    );
    // Fire-and-forget; failures surface via the existing group-crypto logs.
    ref.read(cryptoProvider.notifier).seedInitialGroupKey(conversationId);
  }

  void _handleMention(Map<String, dynamic> json, String myUserId) {
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';
    final content = json['content'] as String? ?? '';

    // Only show notification if someone else mentions us
    final fromUserId = json['from_user_id'] as String? ?? '';
    if (fromUserId == myUserId) return;

    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    final isMuted = conv?.isMuted ?? false;
    if (!isMuted) {
      SoundService().playMessageReceived();
    }
    NotificationService().showMessageNotification(
      senderUsername: '@$fromUsername',
      body: content.length > 100 ? '${content.substring(0, 100)}...' : content,
      conversationId: conversationId,
      conversationName: conv?.displayName(myUserId),
      isGroup: true, // Mentions are always in group contexts
      isMuted: isMuted,
    );

    // Bump unread count for the conversation
    if (conversationId.isNotEmpty) {
      ref
          .read(conversationsProvider.notifier)
          .onNewMessage(
            conversationId: conversationId,
            content: content,
            timestamp: DateTime.now().toIso8601String(),
            senderUsername: fromUsername,
          );
    }
  }
}
