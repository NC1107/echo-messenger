import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';

class ConversationPanel extends ConsumerStatefulWidget {
  final String? selectedConversationId;
  final void Function(Conversation conversation) onConversationTap;
  final VoidCallback? onNewChat;
  final VoidCallback? onSettings;
  final VoidCallback? onShowContacts;

  const ConversationPanel({
    super.key,
    this.selectedConversationId,
    required this.onConversationTap,
    this.onNewChat,
    this.onSettings,
    this.onShowContacts,
  });

  @override
  ConsumerState<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends ConsumerState<ConversationPanel> {
  String _searchQuery = '';
  bool _isSearching = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _clearSearch() {
    setState(() {
      _searchQuery = '';
      _isSearching = false;
      _searchController.clear();
    });
  }

  String _formatTimestamp(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return '';
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inDays > 0) {
        if (diff.inDays == 1) return 'Yesterday';
        if (diff.inDays < 7) {
          const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
          return days[dt.weekday - 1];
        }
        return '${dt.day}/${dt.month}/${dt.year}';
      }

      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(conversationsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';
    final myUsername = ref.watch(authProvider).username ?? 'User';
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

    return Container(
      color: EchoTheme.sidebarBg,
      child: Column(
        children: [
          // Logo header
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                const Text(
                  'Echo',
                  style: TextStyle(
                    color: EchoTheme.textPrimary,
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
                        : EchoTheme.textMuted,
                    shape: BoxShape.circle,
                  ),
                ),
                const Spacer(),
                // New chat icon with pending badge
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      color: EchoTheme.textSecondary,
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
                  color: EchoTheme.surface,
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
                            const Icon(
                              Icons.search_outlined,
                              size: 18,
                              color: EchoTheme.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                autofocus: true,
                                style: const TextStyle(
                                  color: EchoTheme.textPrimary,
                                  fontSize: 13,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'Search conversations',
                                  hintStyle: TextStyle(
                                    color: EchoTheme.textMuted,
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
                                color: EchoTheme.textMuted,
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
                    : const Row(
                        children: [
                          SizedBox(width: 12),
                          Icon(
                            Icons.search_outlined,
                            size: 18,
                            color: EchoTheme.textMuted,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Search conversations',
                            style: TextStyle(
                              color: EchoTheme.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          // Pending requests banner
          if (pendingCount > 0)
            GestureDetector(
              onTap: widget.onShowContacts ?? widget.onSettings,
              child: Container(
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: EchoTheme.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.person_add_outlined,
                      size: 18,
                      color: EchoTheme.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$pendingCount pending request${pendingCount == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: EchoTheme.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: EchoTheme.accent,
                    ),
                  ],
                ),
              ),
            ),
          if (pendingCount > 0) const SizedBox(height: 4),
          // Conversation list
          Expanded(
            child: conversationsState.isLoading && allConversations.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(
                      color: EchoTheme.accent,
                      strokeWidth: 2,
                    ),
                  )
                : conversations.isEmpty
                ? Center(
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
                            color: EchoTheme.textMuted.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'No results found'
                                : 'No conversations yet',
                            style: const TextStyle(
                              color: EchoTheme.textSecondary,
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
                            style: const TextStyle(
                              color: EchoTheme.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 8,
                    ),
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conv = conversations[index];
                      final isSelected =
                          conv.id == widget.selectedConversationId;
                      return _ConversationItem(
                        conversation: conv,
                        myUserId: myUserId,
                        isSelected: isSelected,
                        timestamp: _formatTimestamp(conv.lastMessageTimestamp),
                        onTap: () => widget.onConversationTap(conv),
                      );
                    },
                  ),
          ),
          // User status bar at bottom
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: EchoTheme.mainBg,
              border: Border(
                top: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                // Avatar with online dot
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: EchoTheme.accent,
                      child: Text(
                        myUsername.isNotEmpty
                            ? myUsername[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                          border: Border.all(color: EchoTheme.mainBg, width: 2),
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
                        style: const TextStyle(
                          color: EchoTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Text(
                        'Online',
                        style: TextStyle(
                          color: EchoTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  color: EchoTheme.textSecondary,
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
}

class _ConversationItem extends StatefulWidget {
  final Conversation conversation;
  final String myUserId;
  final bool isSelected;
  final String timestamp;
  final VoidCallback onTap;

  const _ConversationItem({
    required this.conversation,
    required this.myUserId,
    required this.isSelected,
    required this.timestamp,
    required this.onTap,
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
        child: Container(
          height: 68,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? EchoTheme.accentLight
                : _isHovered
                ? EchoTheme.surfaceHover
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              // Avatar with online dot
              Stack(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: conv.isGroup
                        ? EchoTheme.accent
                        : _avatarColor(displayName),
                    child: conv.isGroup
                        ? const Icon(Icons.group, size: 18, color: Colors.white)
                        : Text(
                            displayName.isNotEmpty
                                ? displayName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  if (!conv.isGroup)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: EchoTheme.online,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: widget.isSelected
                                ? EchoTheme.sidebarBg
                                : EchoTheme.sidebarBg,
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
                        Expanded(
                          child: Text(
                            displayName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: hasUnread
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: hasUnread
                                  ? EchoTheme.textPrimary
                                  : EchoTheme.textPrimary,
                            ),
                          ),
                        ),
                        if (widget.timestamp.isNotEmpty)
                          Text(
                            widget.timestamp,
                            style: TextStyle(
                              fontSize: 11,
                              color: hasUnread
                                  ? EchoTheme.accent
                                  : EchoTheme.textMuted,
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
                                color: EchoTheme.textMuted,
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
                              decoration: const BoxDecoration(
                                color: EchoTheme.accent,
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

  Color _avatarColor(String name) {
    final colors = [
      const Color(0xFFE06666),
      const Color(0xFFF6B05C),
      const Color(0xFF57D28F),
      const Color(0xFF5DADE2),
      const Color(0xFFAF7AC5),
      const Color(0xFFEB984E),
    ];
    final index = name.hashCode.abs() % colors.length;
    return colors[index];
  }
}
