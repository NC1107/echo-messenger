part of '../../conversation_panel.dart';

/// Builders for the main conversation list: the tab that selects between
/// skeleton / error / empty / list states, the `ListView.builder` itself
/// (with pinned-section header + divider), per-row tile assembly, and the
/// mobile `Slidable` swipe-action wrapper.
mixin _ConversationPanelListRendererMixin
    on ConsumerState<ConversationPanel>, _ConversationPanelActionsMixin {
  Widget _buildChatsTab(
    ConversationsState conversationsState,
    List<Conversation> conversations,
    List<Conversation> allConversations,
    String myUserId,
    String serverUrl,
    Set<String> wsOnlineUsers,
  ) {
    final Widget child;
    if (conversationsState.isLoading && allConversations.isEmpty) {
      child = const ConversationListSkeleton(key: ValueKey('skeleton'));
    } else if (conversationsState.error != null && allConversations.isEmpty) {
      child = KeyedSubtree(
        key: const ValueKey('error'),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 40,
                  color: context.textMuted.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  "Couldn't load conversations",
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => ref
                      .read(conversationsProvider.notifier)
                      .loadConversations(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    } else if (conversations.isEmpty) {
      child = KeyedSubtree(
        key: const ValueKey('empty'),
        child: _buildChatsEmptyState(),
      );
    } else {
      // conversations is already sorted + filtered by sortedConversationsProvider.
      child = KeyedSubtree(
        key: const ValueKey('list'),
        child: _buildConversationList(
          conversations,
          myUserId,
          serverUrl,
          wsOnlineUsers,
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }

  Widget _buildChatsEmptyState() {
    final searchQuery = ref.watch(conversationSearchQueryProvider);
    if (searchQuery.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off,
                size: 40,
                color: context.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                "No results found for '$searchQuery'",
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Try a different search term',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    // No conversations yet — show onboarding guidance.
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    return EmptyState(
      icon: Icons.forum_outlined,
      title: 'No conversations yet',
      body: 'Start a new chat or wait for friends to message you.',
      ctaLabel: 'Start a new chat',
      onCta: widget.onNewChat,
      footer: (!isMobile && widget.onShowKeyboardShortcuts != null)
          ? Text(
              'Keyboard shortcuts (Ctrl+/)',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            )
          : null,
    );
  }

  Widget _buildListItem({
    required int index,
    required List<Conversation> sorted,
    required int pinnedCount,
    required String myUserId,
    required String serverUrl,
    required Set<String> wsOnlineUsers,
  }) {
    if (pinnedCount > 0) {
      if (index == 0) {
        return Padding(
          padding: const EdgeInsets.only(left: 8, top: 4, bottom: 2),
          child: Text(
            'PINNED',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
              letterSpacing: 0.5,
            ),
          ),
        );
      }
      if (index == pinnedCount + 1) {
        return Divider(
          height: 12,
          thickness: 1,
          indent: 8,
          endIndent: 8,
          color: context.border,
        );
      }
      final convIndex = index <= pinnedCount ? index - 1 : index - 2;
      if (convIndex >= sorted.length) return const SizedBox.shrink();
      final conv = sorted[convIndex];
      return _buildConversationTile(
        conv,
        conv.isPinned ||
            ref.read(pinnedConversationIdsProvider).contains(conv.id),
        myUserId,
        serverUrl,
        wsOnlineUsers,
      );
    }

    final conv = sorted[index];
    return _buildConversationTile(
      conv,
      conv.isPinned ||
          ref.read(pinnedConversationIdsProvider).contains(conv.id),
      myUserId,
      serverUrl,
      wsOnlineUsers,
    );
  }

  Widget _buildConversationList(
    List<Conversation> sorted,
    String myUserId,
    String serverUrl,
    Set<String> wsOnlineUsers,
  ) {
    // Count how many pinned items are at the front of the sorted list.
    final pinnedIds = ref.watch(pinnedConversationIdsProvider);
    final pinnedCount = sorted
        .where((c) => pinnedIds.contains(c.id) || c.isPinned)
        .length;
    // Extra items: section header for pinned (if any) + divider after pinned.
    final extraItems = pinnedCount > 0 ? 2 : 0;

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(conversationsProvider.notifier).loadConversations(),
      color: context.accent,
      child: Scrollbar(
        thumbVisibility: defaultTargetPlatform != TargetPlatform.iOS,
        // Wrap the list in SlidableAutoCloseBehavior so opening a second row's
        // swipe-action panel automatically closes any previously-open one —
        // matches the iOS Mail / Messages pattern. Without this wrapper each
        // Slidable is independent and several rows can sit half-open at once.
        child: SlidableAutoCloseBehavior(
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            // Use fixed itemExtent when no section headers/dividers for faster layout.
            // Three-way density (UX roadmap Phase 2): cozy / normal / compact.
            itemExtent: extraItems == 0
                ? conversationItemHeightFor(ref.watch(uiDensityProvider))
                : null,
            itemCount: sorted.length + extraItems,
            itemBuilder: (context, index) => _buildListItem(
              index: index,
              sorted: sorted,
              pinnedCount: pinnedCount,
              myUserId: myUserId,
              serverUrl: serverUrl,
              wsOnlineUsers: wsOnlineUsers,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversationTile(
    Conversation conv,
    bool isPinned,
    String myUserId,
    String serverUrl,
    Set<String> wsOnlineUsers,
  ) {
    final peer = conv.isGroup
        ? null
        : conv.members.where((m) => m.userId != myUserId).firstOrNull;
    final isPeerOnline = peer != null && wsOnlineUsers.contains(peer.userId);

    final onlineMemberCount = conv.isGroup
        ? conv.members
              .where(
                (m) => m.userId != myUserId && wsOnlineUsers.contains(m.userId),
              )
              .length
        : 0;

    final item = ConversationItem(
      conversation: conv,
      myUserId: myUserId,
      isSelected: conv.id == widget.selectedConversationId,
      isPinned: isPinned,
      isPeerOnline: isPeerOnline,
      peerAvatarUrl: resolveAvatarUrl(peer?.avatarUrl, serverUrl),
      groupIconUrl: resolveAvatarUrl(conv.iconUrl, serverUrl),
      timestamp: formatConversationTimestamp(conv.lastMessageTimestamp),
      onTap: () => widget.onConversationTap(conv),
      onContextMenu: (position) =>
          _showConversationContextMenu(context, conv, position),
      onTogglePin: () => _togglePin(conv.id),
      onLeave: () => conv.isGroup ? _leaveGroup(conv) : _deleteDm(conv),
      onlineMemberCount: onlineMemberCount,
    );

    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    if (!isMobile) return item;

    return _buildSlidableTile(context, conv, isPinned, item);
  }

  /// Wraps [item] in a [Slidable] with mute / pin / delete swipe actions.
  /// Extracted to keep [_buildConversationTile] under the cognitive-complexity
  /// budget — the action callbacks each capture state-mutating closures.
  Widget _buildSlidableTile(
    BuildContext context,
    Conversation conv,
    bool isPinned,
    Widget item,
  ) {
    return Slidable(
      key: ValueKey(conv.id),
      // Shared groupTag so SlidableAutoCloseBehavior knows these rows
      // belong to one logical list — opening row B closes row A.
      groupTag: 'conversation-list',
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.6,
        children: [
          SlidableAction(
            onPressed: (_) => _toggleMuteWithFeedback(conv.id),
            icon: conv.isMuted ? Icons.volume_up : Icons.volume_off,
            backgroundColor: Colors.blueGrey,
            label: conv.isMuted ? 'Unmute' : 'Mute',
          ),
          SlidableAction(
            onPressed: (_) => _togglePin(conv.id),
            icon: Icons.push_pin,
            backgroundColor: Colors.orange,
            label: isPinned ? 'Unpin' : 'Pin',
          ),
          SlidableAction(
            onPressed: (_) =>
                conv.isGroup ? _leaveGroup(conv) : _deleteDm(conv),
            icon: Icons.delete_outline,
            backgroundColor: EchoTheme.danger,
            label: conv.isGroup ? 'Leave' : 'Delete',
          ),
        ],
      ),
      child: item,
    );
  }
}
