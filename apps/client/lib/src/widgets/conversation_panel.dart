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
import '../screens/user_profile_screen.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart';
import 'contact_item.dart';
import 'conversation_item.dart';
import 'echo_logo_icon.dart';
import 'skeleton_loader.dart';

// Re-export avatar utilities so existing `show` imports keep working.
export 'avatar_utils.dart' show buildAvatar, avatarColor, groupAvatarColor;

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

  /// 0 = Chats, 1 = Contacts, 2 = Groups
  int _selectedTab = 0;

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

  void _onTabSelected(int index) {
    setState(() => _selectedTab = index);
    if (index <= 1) {
      final authState = ref.read(authProvider);
      if (authState.isLoggedIn) {
        ref.read(contactsProvider.notifier).loadPending(force: true);
      }
    }
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
      ],
    ).then((value) {
      if (value == 'pin') {
        _togglePin(conv.id);
      } else if (value == 'mute') {
        ref.read(conversationsProvider.notifier).toggleMute(conv.id);
      } else if (value == 'leave_group') {
        _leaveGroup(conv);
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

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(conversationsProvider);
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

    final allConversations = conversationsState.conversations;

    final conversations = _filterConversations(allConversations, userId);
    final groupConversations = conversations.where((c) => c.isGroup).toList();

    return Container(
      color: context.sidebarBg,
      child: Column(
        children: [
          _buildLogoHeader(context, wsConnected, pendingCount),
          _buildSearchBar(context),
          _buildTabBar(),
          const SizedBox(height: 8),
          _buildReplacedBanner(context, wsReplaced),
          Expanded(
            child: _buildTabContent(
              conversationsState: conversationsState,
              conversations: conversations,
              groupConversations: groupConversations,
              allConversations: allConversations,
              contactsState: contactsState,
              myUserId: userId,
              serverUrl: serverUrl,
              wsOnlineUsers: wsOnlineUsers,
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
    if (_searchQuery.isEmpty) return allConversations;
    return allConversations.where((conv) {
      final query = _searchQuery.toLowerCase();
      final name = conv.displayName(myUserId).toLowerCase();
      final lastMsg = (conv.lastMessage ?? '').toLowerCase();
      return name.contains(query) || lastMsg.contains(query);
    }).toList();
  }

  Widget _buildLogoHeader(
    BuildContext context,
    bool wsConnected,
    int pendingCount,
  ) {
    final totalUnread = ref.watch(
      conversationsProvider.select(
        (s) => s.conversations.fold<int>(0, (sum, c) => sum + c.unreadCount),
      ),
    );

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          _buildLogoWithBadge(totalUnread),
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
          _buildNewChatButton(context, pendingCount),
          IconButton(
            icon: const Icon(Icons.group_add_outlined, size: 18),
            color: context.textSecondary,
            tooltip: 'New Group',
            onPressed: widget.onNewGroup,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
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

  Widget _buildLogoWithBadge(int totalUnread) {
    if (totalUnread <= 0) {
      return const EchoLogoIcon(size: 24);
    }
    final label = totalUnread > 99 ? '99+' : '$totalUnread';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const EchoLogoIcon(size: 24),
        Positioned(
          top: -6,
          right: -10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            decoration: BoxDecoration(
              color: EchoTheme.danger,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
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

  Widget _buildNewChatButton(BuildContext context, int pendingCount) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.person_add_outlined, size: 18),
          color: context.textSecondary,
          tooltip: 'New Chat',
          onPressed: widget.onNewChat,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        if (pendingCount > 0)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: EchoTheme.danger,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  pendingCount > 9 ? '9+' : '$pendingCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
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
        Text(
          'Search conversations',
          style: TextStyle(color: context.textMuted, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 300;
          return Row(
            children: [
              _buildTabChip(
                'Chats',
                0,
                icon: narrow ? Icons.chat_bubble_outline : null,
              ),
              const SizedBox(width: 6),
              _buildTabChip(
                'Contacts',
                1,
                icon: narrow ? Icons.people_outline : null,
              ),
              const SizedBox(width: 6),
              _buildTabChip(
                'Groups',
                2,
                icon: narrow ? Icons.groups_outlined : null,
              ),
            ],
          );
        },
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
            height: 48,
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
          imageUrl: avatarUrl != null ? '$serverUrl$avatarUrl' : null,
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

  Widget _buildTabChip(String label, int index, {IconData? icon}) {
    final isSelected = _selectedTab == index;
    final chipColor = isSelected
        ? Theme.of(context).colorScheme.onPrimary
        : context.textSecondary;
    final chipWeight = isSelected ? FontWeight.w600 : FontWeight.w500;
    return Expanded(
      child: GestureDetector(
        onTap: () => _onTabSelected(index),
        child: Container(
          height: 30,
          decoration: BoxDecoration(
            color: isSelected ? context.accent : context.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: icon != null
                ? Icon(icon, size: 16, color: chipColor)
                : Text(
                    label,
                    style: TextStyle(
                      color: chipColor,
                      fontSize: 12,
                      fontWeight: chipWeight,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent({
    required ConversationsState conversationsState,
    required List<Conversation> conversations,
    required List<Conversation> groupConversations,
    required List<Conversation> allConversations,
    required ContactsState contactsState,
    required String myUserId,
    required String serverUrl,
    required Set<String> wsOnlineUsers,
  }) {
    switch (_selectedTab) {
      case 1:
        return _buildContactsTab(contactsState, myUserId, serverUrl);
      case 2:
        return _buildGroupsTab(groupConversations, myUserId);
      default:
        return _buildChatsTab(
          conversationsState,
          conversations,
          allConversations,
          myUserId,
          serverUrl,
          wsOnlineUsers,
        );
    }
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _searchQuery.isNotEmpty ? Icons.search_off : Icons.forum_outlined,
              size: 40,
              color: context.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty
                  ? "No results found for '$_searchQuery'"
                  : 'No conversations yet',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Try a different search term'
                  : 'Add a contact to start messaging',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
            if (_searchQuery.isEmpty) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 34,
                child: FilledButton.icon(
                  onPressed: widget.onNewChat,
                  icon: const Icon(Icons.chat_outlined, size: 16),
                  label: const Text('New Chat'),
                ),
              ),
            ],
          ],
        ),
      ),
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
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        itemCount: sorted.length + extraItems,
        itemBuilder: (context, index) {
          if (pinnedCount > 0) {
            // First item: "PINNED" section header
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
            // After pinned items: divider
            if (index == pinnedCount + 1) {
              return Divider(
                height: 12,
                thickness: 1,
                indent: 8,
                endIndent: 8,
                color: context.border,
              );
            }
            // Adjust index for the extra header/divider items
            final convIndex = index <= pinnedCount ? index - 1 : index - 2;
            if (convIndex >= sorted.length) {
              return const SizedBox.shrink();
            }
            final conv = sorted[convIndex];
            final isPinned = _pinnedIds.contains(conv.id);
            return _buildConversationTile(
              conv,
              isPinned,
              myUserId,
              serverUrl,
              wsOnlineUsers,
            );
          }

          // No pinned items — render normally
          final conv = sorted[index];
          final isPinned = _pinnedIds.contains(conv.id);
          return _buildConversationTile(
            conv,
            isPinned,
            myUserId,
            serverUrl,
            wsOnlineUsers,
          );
        },
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
    String? peerAvatarUrl;
    if (!conv.isGroup && peer != null && peer.avatarUrl != null) {
      peerAvatarUrl = '$serverUrl${peer.avatarUrl}';
    }
    return ConversationItem(
      conversation: conv,
      myUserId: myUserId,
      isSelected: conv.id == widget.selectedConversationId,
      isPinned: isPinned,
      isPeerOnline: isPeerOnline,
      peerAvatarUrl: peerAvatarUrl,
      timestamp: formatConversationTimestamp(conv.lastMessageTimestamp),
      onTap: () => widget.onConversationTap(conv),
      onContextMenu: (position) =>
          _showConversationContextMenu(context, conv, position),
    );
  }

  Widget _buildContactsTab(
    ContactsState contactsState,
    String myUserId,
    String serverUrl,
  ) {
    final contacts = contactsState.contacts;

    if (contactsState.isLoading && contacts.isEmpty) {
      return const ConversationListSkeleton(count: 4);
    }

    if (contacts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.people_outline,
                size: 40,
                color: context.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'No contacts yet',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Add a contact to get started',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 34,
                child: FilledButton.icon(
                  onPressed: widget.onNewChat,
                  icon: const Icon(Icons.person_add_alt_1, size: 16),
                  label: const Text('Add Contact'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      itemCount: contacts.length,
      itemBuilder: (context, index) {
        final contact = contacts[index];
        return ContactItem(
          contact: contact,
          serverUrl: serverUrl,
          onMessage: () {
            widget.onMessageContact?.call(contact.userId, contact.username);
          },
          onProfile: () {
            UserProfileScreen.show(context, ref, contact.userId);
          },
        );
      },
    );
  }

  Widget _buildGroupsTab(
    List<Conversation> groupConversations,
    String myUserId,
  ) {
    if (groupConversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _searchQuery.isNotEmpty
                    ? Icons.search_off
                    : Icons.group_outlined,
                size: 40,
                color: context.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                _searchQuery.isNotEmpty
                    ? "No results found for '$_searchQuery'"
                    : 'No groups yet',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _searchQuery.isNotEmpty
                    ? 'Try a different search term'
                    : 'Create or join a group',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
              if (_searchQuery.isEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    SizedBox(
                      height: 34,
                      child: FilledButton.icon(
                        onPressed: widget.onNewGroup,
                        icon: const Icon(Icons.group_add, size: 16),
                        label: const Text('Create Group'),
                      ),
                    ),
                    SizedBox(
                      height: 34,
                      child: OutlinedButton.icon(
                        onPressed: widget.onDiscover,
                        icon: const Icon(Icons.explore_outlined, size: 16),
                        label: const Text('Discover'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }

    final sorted = _sortConversations(groupConversations);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      itemCount: sorted.length + 1,
      itemBuilder: (context, index) {
        // First item: Discover Groups button
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 2),
            child: OutlinedButton.icon(
              onPressed: widget.onDiscover,
              icon: const Icon(Icons.explore_outlined, size: 16),
              label: const Text('Discover Groups'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 34),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
          );
        }
        final conv = sorted[index - 1];
        final isSelected = conv.id == widget.selectedConversationId;
        final isPinned = _pinnedIds.contains(conv.id);
        // Groups don't have a single peer, so isPeerOnline is always false
        return ConversationItem(
          conversation: conv,
          myUserId: myUserId,
          isSelected: isSelected,
          isPinned: isPinned,
          isPeerOnline: false,
          timestamp: formatConversationTimestamp(conv.lastMessageTimestamp),
          onTap: () => widget.onConversationTap(conv),
          onContextMenu: (position) =>
              _showConversationContextMenu(context, conv, position),
        );
      },
    );
  }
}
