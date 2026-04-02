import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';

/// Shared avatar builder used across conversation panel widgets.
Widget buildAvatar({
  String? imageUrl,
  required String name,
  required double radius,
  Color? bgColor,
  Widget? fallbackIcon,
}) {
  if (imageUrl != null && imageUrl.isNotEmpty) {
    return CircleAvatar(
      radius: radius,
      backgroundImage: NetworkImage(imageUrl),
    );
  }
  return CircleAvatar(
    radius: radius,
    backgroundColor: bgColor ?? avatarColor(name),
    child:
        fallbackIcon ??
        Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.8,
            fontWeight: FontWeight.w600,
          ),
        ),
  );
}

/// Deterministic color from a name string.
Color avatarColor(String name) {
  const colors = [
    Color(0xFFE06666),
    Color(0xFFF6B05C),
    Color(0xFF57D28F),
    Color(0xFF5DADE2),
    Color(0xFFAF7AC5),
    Color(0xFFEB984E),
  ];
  final index = name.hashCode.abs() % colors.length;
  return colors[index];
}

/// Wider palette for group avatars, derived from group name hash.
const _groupColors = [
  Color(0xFF22C55E), // green
  Color(0xFFEF4444), // red
  Color(0xFF3B82F6), // blue
  Color(0xFFF59E0B), // amber
  Color(0xFF8B5CF6), // violet
  Color(0xFFEC4899), // pink
  Color(0xFF14B8A6), // teal
  Color(0xFFF97316), // orange
  Color(0xFF6366F1), // indigo
  Color(0xFF06B6D4), // cyan
];

/// Deterministic color for group avatars.
Color groupAvatarColor(String name) {
  return _groupColors[name.hashCode.abs() % _groupColors.length];
}

class ConversationPanel extends ConsumerStatefulWidget {
  final String? selectedConversationId;
  final void Function(Conversation conversation) onConversationTap;
  final VoidCallback? onNewChat;
  final VoidCallback? onNewGroup;
  final VoidCallback? onDiscover;
  final VoidCallback? onSettings;
  final VoidCallback? onShowContacts;

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
    this.onSettings,
    this.onShowContacts,
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
  Timer? _pendingRefreshTimer;

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
    _pendingRefreshTimer?.cancel();
    widget.externalSearchFocusNode?.removeListener(_onExternalSearchFocus);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _startPendingRefreshLoop() {
    _refreshPendingRequests(force: true);
    _pendingRefreshTimer?.cancel();
    _pendingRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshPendingRequests();
    });
  }

  void _refreshPendingRequests({bool force = false}) {
    final authState = ref.read(authProvider);
    if (!authState.isLoggedIn) {
      return;
    }
    ref.read(contactsProvider.notifier).loadPending(force: force);
  }

  void _onTabSelected(int index) {
    setState(() => _selectedTab = index);
    if (index <= 1) {
      _refreshPendingRequests(force: true);
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
        if (conv.isGroup)
          PopupMenuItem<String>(
            value: 'leave_group',
            child: Row(
              children: [
                Icon(Icons.exit_to_app, size: 16, color: EchoTheme.danger),
                const SizedBox(width: 8),
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
        title: Text(
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
      final serverUrl = ref.read(serverUrlProvider);
      final token = ref.read(authProvider).token;
      if (token == null) return;

      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/${conv.id}/leave'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have left the group.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to leave group (${response.statusCode})'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error leaving group: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(conversationsProvider);
    final authState = ref.watch(authProvider);
    final myUserId = authState.userId ?? '';
    final myUsername = authState.username ?? 'User';
    final serverUrl = ref.watch(serverUrlProvider);
    final wsState = ref.watch(websocketProvider);
    final contactsState = ref.watch(contactsProvider);

    final pendingCount = contactsState.pendingRequests.length;

    final allConversations = conversationsState.conversations;

    // Filter conversations by search query
    final conversations = _searchQuery.isEmpty
        ? allConversations
        : allConversations.where((conv) {
            final query = _searchQuery.toLowerCase();
            final name = conv.displayName(myUserId).toLowerCase();
            final lastMsg = (conv.lastMessage ?? '').toLowerCase();
            return name.contains(query) || lastMsg.contains(query);
          }).toList();

    // Group conversations only
    final groupConversations = conversations.where((c) => c.isGroup).toList();

    return Container(
      color: context.sidebarBg,
      child: Column(
        children: [
          // Logo header
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                Text(
                  'Echo',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: wsState.isConnected
                        ? EchoTheme.online
                        : context.textMuted,
                    shape: BoxShape.circle,
                  ),
                ),
                const Spacer(),
                // Three action icons
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.person_add_outlined, size: 18),
                          color: context.textSecondary,
                          tooltip: 'New Chat',
                          onPressed: widget.onNewChat,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
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
                    ),
                    IconButton(
                      icon: const Icon(Icons.group_add_outlined, size: 18),
                      color: context.textSecondary,
                      tooltip: 'New Group',
                      onPressed: widget.onNewGroup,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.explore_outlined, size: 18),
                      color: context.textSecondary,
                      tooltip: 'Discover Groups',
                      onPressed: widget.onDiscover,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Search bar
          Padding(
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
                    ? KeyboardListener(
                        focusNode: FocusNode(),
                        onKeyEvent: (event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.escape) {
                            _clearSearch();
                          }
                        },
                        child: Row(
                          children: [
                            const SizedBox(width: 12),
                            Icon(
                              Icons.search_outlined,
                              size: 18,
                              color: context.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                autofocus: true,
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Search conversations',
                                  hintStyle: TextStyle(
                                    color: context.textMuted,
                                    fontSize: 13,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
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
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                              )
                            else
                              const SizedBox(width: 8),
                          ],
                        ),
                      )
                    : Row(
                        children: [
                          const SizedBox(width: 12),
                          Icon(
                            Icons.search_outlined,
                            size: 18,
                            color: context.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Search conversations',
                            style: TextStyle(
                              color: context.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          // Tab bar: Chats / Contacts / Groups
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildTabChip('Chats', 0),
                const SizedBox(width: 6),
                _buildTabChip('Contacts', 1),
                const SizedBox(width: 6),
                _buildTabChip('Groups', 2),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Pending requests banner (show only on Chats or Contacts tab)
          if (pendingCount > 0 && _selectedTab <= 1)
            GestureDetector(
              onTap: widget.onShowContacts ?? widget.onSettings,
              child: Container(
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: context.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: context.accent.withValues(alpha: 0.45),
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.person_add_outlined,
                      size: 18,
                      color: context.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$pendingCount pending request${pendingCount == 1 ? '' : 's'}',
                        style: TextStyle(
                          color: context.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 18, color: context.accent),
                  ],
                ),
              ),
            ),
          if (pendingCount > 0 && _selectedTab <= 1) const SizedBox(height: 4),
          // Tab content
          Expanded(
            child: _buildTabContent(
              conversationsState: conversationsState,
              conversations: conversations,
              groupConversations: groupConversations,
              allConversations: allConversations,
              contactsState: contactsState,
              myUserId: myUserId,
            ),
          ),
          // User status bar at bottom
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: context.mainBg,
              border: Border(top: BorderSide(color: context.border, width: 1)),
            ),
            child: Row(
              children: [
                // Avatar with connection dot
                Stack(
                  children: [
                    buildAvatar(
                      name: myUsername,
                      radius: 16,
                      bgColor: context.accent,
                      imageUrl: authState.avatarUrl != null
                          ? '$serverUrl${authState.avatarUrl}'
                          : null,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: wsState.isConnected
                              ? EchoTheme.online
                              : EchoTheme.warning,
                          shape: BoxShape.circle,
                          border: Border.all(color: context.mainBg, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
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
                        wsState.isConnected ? 'Online' : 'Reconnecting...',
                        style: TextStyle(
                          color: wsState.isConnected
                              ? EchoTheme.online
                              : EchoTheme.warning,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  color: context.textSecondary,
                  tooltip: 'Settings',
                  onPressed: widget.onSettings,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabChip(String label, int index) {
    final isSelected = _selectedTab == index;
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
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : context.textSecondary,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
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
  }) {
    switch (_selectedTab) {
      case 1:
        return _buildContactsTab(contactsState, myUserId);
      case 2:
        return _buildGroupsTab(groupConversations, myUserId);
      default:
        return _buildChatsTab(
          conversationsState,
          conversations,
          allConversations,
          myUserId,
        );
    }
  }

  Widget _buildChatsTab(
    ConversationsState conversationsState,
    List<Conversation> conversations,
    List<Conversation> allConversations,
    String myUserId,
  ) {
    if (conversationsState.isLoading && allConversations.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: context.accent, strokeWidth: 2),
      );
    }
    if (conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _searchQuery.isNotEmpty
                    ? Icons.search_off
                    : Icons.forum_outlined,
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
                    : 'Start a new chat to get going',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final sorted = _sortConversations(conversations);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final conv = sorted[index];
        final isSelected = conv.id == widget.selectedConversationId;
        final isPinned = _pinnedIds.contains(conv.id);
        final wsState = ref.watch(websocketProvider);
        final peer = conv.isGroup
            ? null
            : conv.members.where((m) => m.userId != myUserId).firstOrNull;
        final isPeerOnline = peer != null && wsState.isUserOnline(peer.userId);
        final serverUrl = ref.watch(serverUrlProvider);
        // For DMs, resolve peer avatar URL
        String? peerAvatarUrl;
        if (!conv.isGroup && peer != null && peer.avatarUrl != null) {
          peerAvatarUrl = '$serverUrl${peer.avatarUrl}';
        }
        return _ConversationItem(
          conversation: conv,
          myUserId: myUserId,
          isSelected: isSelected,
          isPinned: isPinned,
          isPeerOnline: isPeerOnline,
          peerAvatarUrl: peerAvatarUrl,
          timestamp: formatConversationTimestamp(conv.lastMessageTimestamp),
          onTap: () => widget.onConversationTap(conv),
          onContextMenu: (position) =>
              _showConversationContextMenu(context, conv, position),
        );
      },
    );
  }

  Widget _buildContactsTab(ContactsState contactsState, String myUserId) {
    final contacts = contactsState.contacts;

    if (contactsState.isLoading && contacts.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: context.accent, strokeWidth: 2),
      );
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
        final serverUrl = ref.watch(serverUrlProvider);
        return _ContactItem(
          contact: contact,
          serverUrl: serverUrl,
          onMessage: () {
            widget.onMessageContact?.call(contact.userId, contact.username);
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
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final conv = sorted[index];
        final isSelected = conv.id == widget.selectedConversationId;
        final isPinned = _pinnedIds.contains(conv.id);
        // Groups don't have a single peer, so isPeerOnline is always false
        return _ConversationItem(
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

class _ContactItem extends StatefulWidget {
  final dynamic contact;
  final String serverUrl;
  final VoidCallback onMessage;

  const _ContactItem({
    required this.contact,
    required this.serverUrl,
    required this.onMessage,
  });

  @override
  State<_ContactItem> createState() => _ContactItemState();
}

class _ContactItemState extends State<_ContactItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final contact = widget.contact;
    final username = contact.username as String;
    final displayName = contact.displayName as String?;
    final avatarUrl = contact.avatarUrl as String?;
    final fullAvatarUrl = avatarUrl != null
        ? '${widget.serverUrl}$avatarUrl'
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        height: 56,
        margin: const EdgeInsets.symmetric(vertical: 1),
        decoration: BoxDecoration(
          color: _isHovered ? context.surfaceHover : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            // Avatar with online dot
            Stack(
              children: [
                buildAvatar(
                  name: username,
                  radius: 18,
                  imageUrl: fullAvatarUrl,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: EchoTheme.online,
                      shape: BoxShape.circle,
                      border: Border.all(color: context.sidebarBg, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Name
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName ?? username,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: context.textPrimary,
                    ),
                  ),
                  if (displayName != null)
                    Text(
                      '@$username',
                      style: TextStyle(fontSize: 12, color: context.textMuted),
                    ),
                ],
              ),
            ),
            // Message button
            SizedBox(
              height: 28,
              child: Material(
                color: context.accentLight,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: widget.onMessage,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: Text(
                        'Message',
                        style: TextStyle(
                          color: context.accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationItem extends StatefulWidget {
  final Conversation conversation;
  final String myUserId;
  final bool isSelected;
  final bool isPinned;
  final bool isPeerOnline;
  final String? peerAvatarUrl;
  final String timestamp;
  final VoidCallback onTap;
  final void Function(Offset position)? onContextMenu;

  const _ConversationItem({
    required this.conversation,
    required this.myUserId,
    required this.isSelected,
    required this.isPinned,
    required this.isPeerOnline,
    this.peerAvatarUrl,
    required this.timestamp,
    required this.onTap,
    this.onContextMenu,
  });

  @override
  State<_ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends State<_ConversationItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final displayName = conv.displayName(widget.myUserId);
    final hasUnread = conv.unreadCount > 0;

    String? snippet = conv.lastMessage;
    // Mask encrypted / undecryptable previews with a friendly fallback
    if (snippet != null &&
        (snippet.startsWith('[Could not decrypt]') ||
            snippet.startsWith('[Encrypted'))) {
      snippet = '\u{1F512} Encrypted message';
    }
    if (snippet != null && conv.isGroup && conv.lastMessageSender != null) {
      snippet = '${conv.lastMessageSender}: $snippet';
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: (details) {
          widget.onContextMenu?.call(details.globalPosition);
        },
        onLongPressStart: (details) {
          widget.onContextMenu?.call(details.globalPosition);
        },
        child: Container(
          height: 68,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? context.accentLight
                : _isHovered
                ? context.surfaceHover
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              // Avatar with online dot
              Stack(
                children: [
                  buildAvatar(
                    name: displayName,
                    radius: 20,
                    imageUrl: conv.isGroup ? null : widget.peerAvatarUrl,
                    bgColor: conv.isGroup
                        ? groupAvatarColor(displayName)
                        : null,
                    fallbackIcon: conv.isGroup
                        ? const Icon(Icons.group, size: 18, color: Colors.white)
                        : null,
                  ),
                  if (!conv.isGroup)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: widget.isPeerOnline
                              ? EchoTheme.online
                              : context.textMuted,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: context.sidebarBg,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              // Name + snippet
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        if (widget.isPinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.push_pin,
                              size: 12,
                              color: context.textMuted,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            displayName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: hasUnread
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: context.textPrimary,
                            ),
                          ),
                        ),
                        if (widget.timestamp.isNotEmpty)
                          Text(
                            widget.timestamp,
                            style: TextStyle(
                              fontSize: 11,
                              color: hasUnread
                                  ? context.accent
                                  : context.textMuted,
                            ),
                          ),
                      ],
                    ),
                    if (snippet != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              snippet,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: context.textMuted,
                                fontWeight: hasUnread
                                    ? FontWeight.w500
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (hasUnread)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: context.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
