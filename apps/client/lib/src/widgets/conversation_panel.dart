import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart';
import 'conversation_item.dart';
import 'echo_logo_icon.dart';
import 'skeleton_loader.dart';

// Re-export avatar utilities so existing `show` imports keep working.
export 'avatar_utils.dart'
    show buildAvatar, avatarColor, groupAvatarColor, resolveAvatarUrl;

enum _ConversationFilter { all, dms, groups }

class ConversationPanel extends ConsumerStatefulWidget {
  final String? selectedConversationId;
  final void Function(Conversation conversation) onConversationTap;
  final VoidCallback? onNewChat;
  final VoidCallback? onNewGroup;
  final VoidCallback? onDiscover;
  final VoidCallback? onCollapseSidebar;
  final VoidCallback? onSettings;
  final VoidCallback? onShowContacts;
  final VoidCallback? onGlobalSearch;
  final VoidCallback? onSavedMessages;

  /// Called when the user taps "Message" on a contact in the Contacts tab.
  /// Should call getOrCreateDm and then select the conversation.
  final void Function(String userId, String username)? onMessageContact;

  /// Optional external focus node for the search bar (e.g. for Ctrl+K shortcut).
  final FocusNode? externalSearchFocusNode;

  const ConversationPanel({
    super.key,
    this.selectedConversationId,
    required this.onConversationTap,
    this.onNewChat,
    this.onNewGroup,
    this.onDiscover,
    this.onCollapseSidebar,
    this.onSettings,
    this.onShowContacts,
    this.onGlobalSearch,
    this.onSavedMessages,
    this.onMessageContact,
    this.externalSearchFocusNode,
  });

  @override
  ConsumerState<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends ConsumerState<ConversationPanel> {
  String _searchQuery = '';
  bool _isSearching = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _keyboardListenerFocusNode = FocusNode();
  // Timer removed -- HomeScreen handles pending contacts polling

  /// Active conversation type filter.
  _ConversationFilter _filter = _ConversationFilter.all;

  /// Pinned conversation IDs
  Set<String> _pinnedIds = {};

  @override
  void initState() {
    super.initState();
    _loadPinnedIds();
    _startPendingRefreshLoop();
    widget.externalSearchFocusNode?.addListener(_onExternalSearchFocus);
  }

  @override
  void didUpdateWidget(covariant ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalSearchFocusNode != oldWidget.externalSearchFocusNode) {
      oldWidget.externalSearchFocusNode?.removeListener(_onExternalSearchFocus);
      widget.externalSearchFocusNode?.addListener(_onExternalSearchFocus);
    }
    // When a conversation is selected externally, reset the filter so the
    // selected conversation is visible and highlighted.
    if (widget.selectedConversationId != null &&
        widget.selectedConversationId != oldWidget.selectedConversationId &&
        _filter != _ConversationFilter.all) {
      setState(() => _filter = _ConversationFilter.all);
    }
  }

  @override
  void dispose() {
    widget.externalSearchFocusNode?.removeListener(_onExternalSearchFocus);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _keyboardListenerFocusNode.dispose();
    super.dispose();
  }

  // Pending contacts refresh is handled by HomeScreen's timer -- no duplicate here.
  void _startPendingRefreshLoop() {
    // Just do the initial load
    final authState = ref.read(authProvider);
    if (authState.isLoggedIn) {
      ref.read(contactsProvider.notifier).loadPending(force: true);
    }
  }

  void _onFilterChanged(_ConversationFilter filter) {
    if (_filter == filter) return;
    setState(() => _filter = filter);
  }

  void _onExternalSearchFocus() {
    if (widget.externalSearchFocusNode?.hasFocus == true) {
      _activateSearch();
    }
  }

  void _activateSearch() {
    setState(() => _isSearching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  Future<void> _loadPinnedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final pinned = prefs.getStringList('pinned_conversation_ids') ?? [];
    if (mounted) {
      setState(() => _pinnedIds = pinned.toSet());
    }
  }

  Future<void> _savePinnedIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('pinned_conversation_ids', _pinnedIds.toList());
  }

  void _togglePin(String conversationId) {
    setState(() {
      if (_pinnedIds.contains(conversationId)) {
        _pinnedIds.remove(conversationId);
      } else {
        _pinnedIds.add(conversationId);
      }
    });
    _savePinnedIds();
  }

  /// Sort conversations: pinned first, then by last message timestamp.
  /// Both groups are sorted by most recent message descending.
  List<Conversation> _sortConversations(List<Conversation> conversations) {
    final pinned = <Conversation>[];
    final unpinned = <Conversation>[];
    for (final conv in conversations) {
      if (_pinnedIds.contains(conv.id)) {
        pinned.add(conv);
      } else {
        unpinned.add(conv);
      }
    }
    int byTimestamp(Conversation a, Conversation b) {
      final ta = a.lastMessageTimestamp ?? '';
      final tb = b.lastMessageTimestamp ?? '';
      return tb.compareTo(ta); // descending — newest first
    }

    pinned.sort(byTimestamp);
    unpinned.sort(byTimestamp);
    return [...pinned, ...unpinned];
  }

  void _clearSearch() {
    setState(() {
      _searchQuery = '';
      _isSearching = false;
      _searchController.clear();
    });
  }

  void _showConversationContextMenu(
    BuildContext context,
    Conversation conv,
    Offset position,
  ) {
    final isPinned = _pinnedIds.contains(conv.id);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      color: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.border),
      ),
      items: [
        PopupMenuItem<String>(
          value: 'pin',
          child: Row(
            children: [
              Icon(
                isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 16,
                color: context.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                isPinned ? 'Unpin' : 'Pin to top',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'mute',
          child: Row(
            children: [
              Icon(
                conv.isMuted
                    ? Icons.notifications_outlined
                    : Icons.notifications_off_outlined,
                size: 16,
                color: context.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                conv.isMuted ? 'Unmute' : 'Mute',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
        if (conv.isGroup)
          const PopupMenuItem<String>(
            value: 'leave_group',
            child: Row(
              children: [
                Icon(Icons.exit_to_app, size: 16, color: EchoTheme.danger),
                SizedBox(width: 8),
                Text(
                  'Leave Group',
                  style: TextStyle(color: EchoTheme.danger, fontSize: 13),
                ),
              ],
            ),
          ),
        if (!conv.isGroup)
          const PopupMenuItem<String>(
            value: 'delete_dm',
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 16, color: EchoTheme.danger),
                SizedBox(width: 8),
                Text(
                  'Delete Conversation',
                  style: TextStyle(color: EchoTheme.danger, fontSize: 13),
                ),
              ],
            ),
          ),
      ],
    ).then((value) {
      if (value == 'pin') {
        _togglePin(conv.id);
      } else if (value == 'mute') {
        ref.read(conversationsProvider.notifier).toggleMute(conv.id);
      } else if (value == 'leave_group') {
        _leaveGroup(conv);
      } else if (value == 'delete_dm') {
        _deleteDm(conv);
      }
    });
  }

  Future<void> _leaveGroup(Conversation conv) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: const Text(
          'Leave Group',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Are you sure you want to leave "${conv.name ?? "this group"}"?',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

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

  Future<void> _deleteDm(Conversation conv) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: const Text(
          'Delete Conversation',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will remove the conversation from your list. '
          'You can start a new conversation anytime.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

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

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(
      conversationsProvider.select(
        (s) => (s.conversations, s.isLoading, s.error),
      ),
    );
    final (allConversations, convIsLoading, convError) = conversationsState;
    final convState = ConversationsState(
      conversations: allConversations,
      isLoading: convIsLoading,
      error: convError,
    );
    final (myUserId, myUsername, myAvatarUrl) = ref.watch(
      authProvider.select((s) => (s.userId, s.username, s.avatarUrl)),
    );
    final userId = myUserId ?? '';
    final username = myUsername ?? 'User';
    final serverUrl = ref.watch(serverUrlProvider);
    final (wsConnected, wsReplaced, wsOnlineUsers) = ref.watch(
      websocketProvider.select(
        (s) => (s.isConnected, s.wasReplaced, s.onlineUsers),
      ),
    );
    final contactsState = ref.watch(contactsProvider);

    final pendingCount = contactsState.pendingRequests.length;

    final conversations = _filterConversations(allConversations, userId);

    return Container(
      color: context.sidebarBg,
      child: Column(
        children: [
          _buildLogoHeader(context, wsConnected, pendingCount),
          _buildSearchBar(context),
          _buildFilterChips(),
          _buildReplacedBanner(context, wsReplaced),
          if (pendingCount > 0) _buildPendingBanner(pendingCount),
          Expanded(
            child: _buildChatsTab(
              convState,
              conversations,
              allConversations,
              userId,
              serverUrl,
              wsOnlineUsers,
            ),
          ),
          _buildUserStatusBar(
            context,
            myUsername: username,
            serverUrl: serverUrl,
            avatarUrl: myAvatarUrl,
            wsConnected: wsConnected,
            wsReplaced: wsReplaced,
          ),
        ],
      ),
    );
  }

  List<Conversation> _filterConversations(
    List<Conversation> allConversations,
    String myUserId,
  ) {
    var result = allConversations;

    // Apply type filter.
    switch (_filter) {
      case _ConversationFilter.dms:
        result = result.where((c) => !c.isGroup).toList();
      case _ConversationFilter.groups:
        result = result.where((c) => c.isGroup).toList();
      case _ConversationFilter.all:
        break;
    }

    // Apply search filter.
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      result = result.where((conv) {
        final name = conv.displayName(myUserId).toLowerCase();
        final lastMsg = (conv.lastMessage ?? '').toLowerCase();
        return name.contains(query) || lastMsg.contains(query);
      }).toList();
    }

    return result;
  }

  Widget _buildLogoHeader(
    BuildContext context,
    bool wsConnected,
    int pendingCount,
  ) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          const EchoLogoIcon(size: 24),
          const SizedBox(width: 8),
          Text(
            'Echo',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          _buildConnectionDot(context, wsConnected),
          const Spacer(),
          _buildNewActionMenu(context, pendingCount),
          if (widget.onGlobalSearch != null)
            IconButton(
              icon: const Icon(Icons.search_outlined, size: 18),
              color: context.textSecondary,
              tooltip: 'Search messages (Ctrl+Shift+F)',
              onPressed: widget.onGlobalSearch,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          if (widget.onCollapseSidebar != null)
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 16),
              color: context.textMuted,
              tooltip: 'Collapse',
              onPressed: widget.onCollapseSidebar,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
        ],
      ),
    );
  }

  Widget _buildConnectionDot(BuildContext context, bool wsConnected) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: wsConnected ? EchoTheme.online : context.textMuted,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildNewActionMenu(BuildContext context, int pendingCount) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        PopupMenuButton<String>(
          icon: Icon(Icons.add, size: 20, color: context.textSecondary),
          tooltip: 'New',
          padding: EdgeInsets.zero,
          // Button tap target size
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          // Menu minimum width so text never clips on narrow viewports
          menuPadding: const EdgeInsets.symmetric(vertical: 4),
          popUpAnimationStyle: AnimationStyle.noAnimation,
          offset: const Offset(0, 36),
          onSelected: (value) {
            switch (value) {
              case 'chat':
                widget.onNewChat?.call();
              case 'group':
                widget.onNewGroup?.call();
              case 'discover':
                widget.onDiscover?.call();
              case 'saved':
                widget.onSavedMessages?.call();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'chat',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_add_outlined, size: 18),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text('New Chat', overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuItem(
              value: 'group',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.group_add_outlined, size: 18),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text('New Group', overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuItem(
              value: 'discover',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.explore_outlined, size: 18),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text(
                        'Discover Groups',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuItem(
              value: 'saved',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.bookmark_border_outlined, size: 18),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text(
                        'Saved Messages',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (pendingCount > 0)
          Positioned(
            top: 2,
            right: 2,
            child: IgnorePointer(
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  color: EchoTheme.danger,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    pendingCount > 9 ? '9+' : '$pendingCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: GestureDetector(
        onTap: () {
          if (!_isSearching) {
            setState(() => _isSearching = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _searchFocusNode.requestFocus();
            });
          }
        },
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: _isSearching
              ? _buildActiveSearchBar(context)
              : _buildInactiveSearchBar(context),
        ),
      ),
    );
  }

  Widget _buildActiveSearchBar(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyboardListenerFocusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _clearSearch();
        }
      },
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.search_outlined, size: 18, color: context.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              autofocus: true,
              style: TextStyle(color: context.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search conversations',
                hintStyle: TextStyle(color: context.textMuted, fontSize: 13),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                isDense: true,
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.trim();
                });
              },
            ),
          ),
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: context.textMuted,
              onPressed: _clearSearch,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildInactiveSearchBar(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 12),
        Icon(Icons.search_outlined, size: 18, color: context.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Search conversations',
            style: TextStyle(color: context.textMuted, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _buildChip('All', _ConversationFilter.all),
          const SizedBox(width: 6),
          _buildChip(
            'DMs',
            _ConversationFilter.dms,
            icon: Icons.person_outline,
          ),
          const SizedBox(width: 6),
          _buildChip(
            'Groups',
            _ConversationFilter.groups,
            icon: Icons.groups_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildChip(
    String label,
    _ConversationFilter filter, {
    IconData? icon,
  }) {
    final isSelected = _filter == filter;
    final chipColor = isSelected
        ? Theme.of(context).colorScheme.onPrimary
        : context.textSecondary;
    final chipWeight = isSelected ? FontWeight.w600 : FontWeight.w500;
    return GestureDetector(
      onTap: () => _onFilterChanged(filter),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? context.accent : context.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: chipColor),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: chipColor,
                fontSize: 12,
                fontWeight: chipWeight,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingBanner(int pendingCount) {
    return GestureDetector(
      onTap: widget.onShowContacts,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.person_add, size: 16, color: context.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$pendingCount pending contact ${pendingCount == 1 ? 'request' : 'requests'}',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: context.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildReplacedBanner(BuildContext context, bool wsReplaced) {
    if (!wsReplaced) return const SizedBox.shrink();
    return Column(
      children: [
        GestureDetector(
          onTap: () {
            // Trigger a fresh connect (clears wasReplaced and reconnects)
            ref.read(websocketProvider.notifier).connect();
          },
          child: Container(
            height: 56,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: EchoTheme.warning, width: 1),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(
                  Icons.devices_other,
                  size: 18,
                  color: EchoTheme.warning,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Signed in on another device. Tap to reconnect.',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Icon(Icons.refresh, size: 18, color: EchoTheme.warning),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildUserStatusBar(
    BuildContext context, {
    required String myUsername,
    required String serverUrl,
    required String? avatarUrl,
    required bool wsConnected,
    required bool wsReplaced,
  }) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          _buildUserAvatar(
            context,
            myUsername,
            serverUrl,
            avatarUrl,
            wsConnected,
          ),
          const SizedBox(width: 10),
          _buildUserNameAndStatus(context, myUsername, wsConnected, wsReplaced),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 18),
            color: context.textSecondary,
            tooltip: 'Settings',
            onPressed: widget.onSettings,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildUserAvatar(
    BuildContext context,
    String myUsername,
    String serverUrl,
    String? avatarUrl,
    bool wsConnected,
  ) {
    return Stack(
      children: [
        buildAvatar(
          name: myUsername,
          radius: 16,
          bgColor: context.accent,
          imageUrl: resolveAvatarUrl(avatarUrl, serverUrl),
        ),
        Positioned(
          bottom: 0,
          right: 0,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: wsConnected ? EchoTheme.online : EchoTheme.warning,
              shape: BoxShape.circle,
              border: Border.all(color: context.mainBg, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  static String _connectionStatusLabel(bool wsReplaced, bool wsConnected) {
    if (wsReplaced) return 'Session replaced';
    if (wsConnected) return 'Online';
    return 'Reconnecting...';
  }

  Widget _buildUserNameAndStatus(
    BuildContext context,
    String myUsername,
    bool wsConnected,
    bool wsReplaced,
  ) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            myUsername,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            _connectionStatusLabel(wsReplaced, wsConnected),
            style: TextStyle(
              color: wsConnected ? EchoTheme.online : EchoTheme.warning,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

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
      final sorted = _sortConversations(conversations);
      child = KeyedSubtree(
        key: const ValueKey('list'),
        child: _buildConversationList(
          sorted,
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
    if (_searchQuery.isNotEmpty) {
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
                "No results found for '$_searchQuery'",
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: context.textMuted.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 16),
            Text(
              'No conversations yet',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Start chatting by adding a contact or joining a group',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.onNewChat,
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: const Text('Add Contact'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: context.accent),
                  foregroundColor: context.accent,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.onDiscover,
                icon: const Icon(Icons.groups_outlined, size: 18),
                label: const Text('Browse Groups'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: context.border),
                  foregroundColor: context.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
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
        _pinnedIds.contains(conv.id),
        myUserId,
        serverUrl,
        wsOnlineUsers,
      );
    }

    final conv = sorted[index];
    return _buildConversationTile(
      conv,
      _pinnedIds.contains(conv.id),
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
    final pinnedCount = sorted.where((c) => _pinnedIds.contains(c.id)).length;
    // Extra items: section header for pinned (if any) + divider after pinned.
    final extraItems = pinnedCount > 0 ? 2 : 0;

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(conversationsProvider.notifier).loadConversations(),
      color: context.accent,
      child: Scrollbar(
        thumbVisibility: defaultTargetPlatform != TargetPlatform.iOS,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          // Use fixed itemExtent when no section headers/dividers for faster layout.
          itemExtent: extraItems == 0 ? 70 : null,
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
    return ConversationItem(
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
    );
  }
}
