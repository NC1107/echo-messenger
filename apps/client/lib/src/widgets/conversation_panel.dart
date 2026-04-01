import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';

class ConversationPanel extends ConsumerWidget {
  final String? selectedConversationId;
  final void Function(Conversation conversation) onConversationTap;
  final VoidCallback? onNewChat;
  final VoidCallback? onLogout;

  const ConversationPanel({
    super.key,
    this.selectedConversationId,
    required this.onConversationTap,
    this.onNewChat,
    this.onLogout,
  });

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
  Widget build(BuildContext context, WidgetRef ref) {
    final conversationsState = ref.watch(conversationsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';
    final myUsername = ref.watch(authProvider).username ?? 'User';
    final wsState = ref.watch(websocketProvider);

    final conversations = conversationsState.conversations;

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
                IconButton(
                  icon: const Icon(Icons.edit_square, size: 18),
                  color: EchoTheme.textSecondary,
                  tooltip: 'New Chat',
                  onPressed: onNewChat,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: EchoTheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  SizedBox(width: 12),
                  Icon(Icons.search, size: 18, color: EchoTheme.textMuted),
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
          // Conversation list
          Expanded(
            child: conversationsState.isLoading && conversations.isEmpty
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
                                Icons.forum_outlined,
                                size: 40,
                                color: EchoTheme.textMuted
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'No conversations yet',
                                style: TextStyle(
                                  color: EchoTheme.textSecondary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Start a new chat to get going',
                                textAlign: TextAlign.center,
                                style: TextStyle(
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
                            vertical: 4, horizontal: 8),
                        itemCount: conversations.length,
                        itemBuilder: (context, index) {
                          final conv = conversations[index];
                          final isSelected =
                              conv.id == selectedConversationId;
                          return _ConversationItem(
                            conversation: conv,
                            myUserId: myUserId,
                            isSelected: isSelected,
                            timestamp:
                                _formatTimestamp(conv.lastMessageTimestamp),
                            onTap: () => onConversationTap(conv),
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
                          border: Border.all(
                            color: EchoTheme.mainBg,
                            width: 2,
                          ),
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
                  tooltip: 'Settings / Logout',
                  onPressed: onLogout,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
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
    if (snippet != null && conv.isGroup && conv.lastMessageSender != null) {
      snippet = '${conv.lastMessageSender}: $snippet';
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 72,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? EchoTheme.accentLight
                : _isHovered
                    ? EchoTheme.hoverBg
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
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
                                ? const Color(0xFF1A2A4A)
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
