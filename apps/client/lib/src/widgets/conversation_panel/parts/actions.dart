part of '../../conversation_panel.dart';

/// Action handlers + small lifecycle helpers extracted from
/// `_ConversationPanelState`: pinning, mute, mark-as-read, leave/delete,
/// and the conversation-target / context-menu builders.
///
/// Implemented as a mixin on `ConsumerState<ConversationPanel>` so it can
/// reach `ref`, `widget`, `context`, and `mounted` — same trick the
/// `auth_token_storage` part uses on the AuthNotifier codegen base.
mixin _ConversationPanelActionsMixin on ConsumerState<ConversationPanel> {
  // Pending contacts refresh is handled by HomeScreen's timer -- no duplicate here.
  void _startPendingRefreshLoop() {
    // Just do the initial load
    final authState = ref.read(authProvider);
    if (authState.isLoggedIn) {
      ref.read(contactsProvider.notifier).loadPending(force: true);
    }
  }

  void _onFilterChanged(ConversationFilterType filter) {
    if (ref.read(conversationFilterTypeProvider) == filter) return;
    ref.read(conversationFilterTypeProvider.notifier).set(filter);
  }

  Future<void> _loadPinnedIds() async {
    // Seed from SharedPreferences for immediate rendering before server load.
    final prefs = await SharedPreferences.getInstance();
    final pinned = prefs.getStringList('pinned_conversation_ids') ?? [];
    if (mounted) {
      // Merge SharedPrefs IDs with any server-known pinned conversations.
      final serverPinned = ref
          .read(conversationsProvider)
          .conversations
          .where((c) => c.isPinned)
          .map((c) => c.id)
          .toSet();
      ref.read(pinnedConversationIdsProvider.notifier).set({
        ...pinned.toSet(),
        ...serverPinned,
      });
    }
  }

  Future<void> _savePinnedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = ref.read(pinnedConversationIdsProvider);
    await prefs.setStringList('pinned_conversation_ids', ids.toList());
  }

  void _togglePin(String conversationId) {
    final current = ref.read(pinnedConversationIdsProvider);
    final isPinned = current.contains(conversationId);
    final updated = Set<String>.from(current);
    if (isPinned) {
      updated.remove(conversationId);
    } else {
      updated.add(conversationId);
    }
    ref.read(pinnedConversationIdsProvider.notifier).set(updated);
    _savePinnedIds();
    ref
        .read(conversationsProvider.notifier)
        .setPinned(conversationId, !isPinned);
  }

  /// Build a [ConversationTarget] for [conv] using the current
  /// pinned-ids set, mute state, and the my-role lookup from the
  /// conversation member list. The handlers wired here are the
  /// existing in-panel methods (no new business logic introduced by
  /// this migration); the centralised menu is purely a *surface*
  /// swap.
  ConversationTarget _buildConversationTarget(Conversation conv) {
    final myUserId = ref.read(authProvider).userId ?? '';
    final myMember = conv.members
        .where((m) => m.userId == myUserId)
        .firstOrNull;
    final myRole = myMember?.role ?? 'member';
    final isAdminOrOwner = myRole == 'owner' || myRole == 'admin';
    final pinnedIds = ref.read(pinnedConversationIdsProvider);
    final isPinned = pinnedIds.contains(conv.id) || conv.isPinned;
    final hasUnread = conv.unreadCount > 0 || conv.mentionCount > 0;
    final canLeave = _resolveCanLeave(conv, myRole, myUserId);
    final canDeleteGroup = conv.isGroup && myRole == 'owner';
    final canInviteOrManage = conv.isGroup && isAdminOrOwner;

    return ConversationTarget(
      conversationId: conv.id,
      isGroup: conv.isGroup,
      isPinned: isPinned,
      isMuted: conv.isMuted,
      hasUnread: hasUnread,
      isAdminOrOwner: isAdminOrOwner,
      onMarkAsRead: hasUnread ? () => _markRead(conv.id) : null,
      // Mark-as-unread isn't wired to a real provider yet; defer to a
      // follow-up so we don't introduce dead UI here.
      onMarkAsUnread: null,
      onToggleMute: () => _toggleMute(conv.id),
      onTogglePin: () => _togglePin(conv.id),
      onOpenInfo: conv.isGroup
          ? () => context.go('/group-info/${conv.id}')
          : null,
      // Invite-people / encryption-activity link out to existing
      // routes today; centralising the entry points is enough for v1.
      onInvitePeople: canInviteOrManage
          ? () => context.go('/group-info/${conv.id}')
          : null,
      onOpenEncryptionActivity: canInviteOrManage
          ? () => context.go('/group-info/${conv.id}')
          : null,
      onViewSafetyNumber: _resolveSafetyNumberCallback(
        conv,
        myMember,
        myUserId,
      ),
      onCopyId: () => _copyConversationId(conv.id),
      onLeave: canLeave ? () => _leaveGroup(conv) : null,
      onDelete: _resolveDeleteCallback(conv, canDeleteGroup),
    );
  }

  // The owner of a group with other members can't leave (the server
  // enforces this); per the cross-cutting decision we hide the row
  // entirely rather than render it disabled.
  bool _resolveCanLeave(Conversation conv, String myRole, String myUserId) {
    if (!conv.isGroup) return false;
    final ownerWithMembers =
        myRole == 'owner' &&
        conv.members.where((m) => m.userId != myUserId).isNotEmpty;
    return !ownerWithMembers;
  }

  void _markRead(String conversationId) {
    unawaited(
      ref.read(conversationsProvider.notifier).sendReadReceipt(conversationId),
    );
  }

  Future<void> _toggleMute(String conversationId) async {
    final ok = await ref
        .read(conversationsProvider.notifier)
        .toggleMute(conversationId);
    if (!ok && mounted) {
      ToastService.show(
        context,
        'Failed to update mute settings',
        type: ToastType.error,
      );
    }
  }

  VoidCallback? _resolveSafetyNumberCallback(
    Conversation conv,
    dynamic myMember,
    String myUserId,
  ) {
    if (conv.isGroup || myMember == null) return null;
    return () {
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      if (peer != null) {
        context.go('/safety-number/${peer.userId}');
      }
    };
  }

  void _copyConversationId(String conversationId) {
    copyToClipboard(
      context,
      conversationId,
      successMessage: 'Conversation ID copied',
    );
  }

  VoidCallback? _resolveDeleteCallback(Conversation conv, bool canDeleteGroup) {
    if (!conv.isGroup) return () => _deleteDm(conv);
    return canDeleteGroup ? () => _deleteGroup(conv) : null;
  }

  void _showConversationContextMenu(
    BuildContext context,
    Conversation conv,
    Offset position,
  ) {
    final target = _buildConversationTarget(conv);
    EchoContextMenu.open(
      context: context,
      target: target,
      anchor: position,
      model: buildConversationMenu(target),
    );
  }

  Future<void> _leaveGroup(Conversation conv) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Leave Group',
      content: 'Are you sure you want to leave "${conv.name ?? "this group"}"?',
      confirmLabel: 'Leave',
      destructive: true,
    );

    if (!confirmed || !mounted) return;

    try {
      final success = await ref
          .read(conversationsProvider.notifier)
          .leaveGroup(conv.id);

      if (!mounted) return;

      if (success) {
        ToastService.show(
          context,
          'You have left the group.',
          type: ToastType.success,
        );
      } else {
        ToastService.show(
          context,
          'Failed to leave group',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Error leaving group: $e',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _deleteGroup(Conversation conv) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Delete Group',
      content:
          'This will permanently delete "${conv.name ?? "this group"}" '
          'and all its messages for everyone. This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );

    if (!confirmed || !mounted) return;

    try {
      final success = await ref
          .read(conversationsProvider.notifier)
          .deleteGroup(conv.id);

      if (!mounted) return;

      if (success) {
        ToastService.show(context, 'Group deleted.', type: ToastType.success);
      } else {
        ToastService.show(
          context,
          'Failed to delete group',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Error deleting group: $e',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _deleteDm(Conversation conv) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Delete Conversation',
      content:
          'This will remove the conversation from your list. '
          'You can start a new conversation anytime.',
      confirmLabel: 'Delete',
      destructive: true,
    );

    if (!confirmed || !mounted) return;

    final success = await ref
        .read(conversationsProvider.notifier)
        .leaveConversation(conv.id);

    if (!mounted) return;

    if (success) {
      ToastService.show(
        context,
        'Conversation deleted',
        type: ToastType.success,
      );
    } else {
      ToastService.show(
        context,
        'Failed to delete conversation',
        type: ToastType.error,
      );
    }
  }

  Future<void> _toggleMuteWithFeedback(String conversationId) async {
    final ok = await ref
        .read(conversationsProvider.notifier)
        .toggleMute(conversationId);
    if (!ok && mounted) {
      ToastService.show(
        context,
        'Failed to update mute settings',
        type: ToastType.error,
      );
    }
  }
}
