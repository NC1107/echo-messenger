import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../theme/echo_theme.dart';
import 'user_status_bar.dart';

class ConversationPanel extends ConsumerWidget {
  final String? selectedConversationId;
  final void Function(Conversation conversation) onConversationTap;
  final String? filterGroupId;
  final VoidCallback? onNewChat;

  const ConversationPanel({
    super.key,
    this.selectedConversationId,
    required this.onConversationTap,
    this.filterGroupId,
    this.onNewChat,
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

    // Filter conversations based on context
    List<Conversation> conversations;
    String headerTitle;

    if (filterGroupId != null) {
      // Show only the specific group (channels view - for now just the group)
      final group = conversationsState.conversations
          .where((c) => c.id == filterGroupId)
          .toList();
      conversations = group;
      headerTitle = group.isNotEmpty
          ? group.first.displayName(myUserId)
          : 'Server';
    } else {
      // DM mode: show DMs (non-group conversations)
      conversations = conversationsState.conversations
          .where((c) => !c.isGroup)
          .toList();
      headerTitle = 'Direct Messages';
    }

    return Container(
      width: 240,
      color: EchoTheme.panelBg,
      child: Column(
        children: [
          // Header
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: EchoTheme.background, width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    headerTitle,
                    style: const TextStyle(
                      color: EchoTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (filterGroupId == null)
                  IconButton(
                    icon: const Icon(Icons.edit, size: 18),
                    color: EchoTheme.textSecondary,
                    tooltip: 'New Chat',
                    onPressed: onNewChat,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
              ],
            ),
          ),
          // Search placeholder
          Padding(
            padding: const EdgeInsets.all(8),
            child: Container(
              height: 28,
              decoration: BoxDecoration(
                color: EchoTheme.background,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Row(
                children: [
                  SizedBox(width: 8),
                  Icon(Icons.search, size: 16, color: EchoTheme.textMuted),
                  SizedBox(width: 6),
                  Text(
                    'Find or start a conversation',
                    style: TextStyle(
                      color: EchoTheme.textMuted,
                      fontSize: 12,
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
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            filterGroupId != null
                                ? 'No channels yet.'
                                : 'No conversations yet.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: EchoTheme.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: conversations.length,
                        itemBuilder: (context, index) {
                          final conv = conversations[index];
                          final isSelected =
                              conv.id == selectedConversationId;
                          return _ConversationItem(
                            conversation: conv,
                            myUserId: myUserId,
                            isSelected: isSelected,
                            timestamp: _formatTimestamp(
                                conv.lastMessageTimestamp),
                            onTap: () => onConversationTap(conv),
                          );
                        },
                      ),
          ),
          // User status bar at bottom
          const UserStatusBar(),
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
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? EchoTheme.activeBg
                : _isHovered
                    ? EchoTheme.hoverBg
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                // Left accent border for active conversation
                if (widget.isSelected)
                  Container(
                    width: 4,
                    decoration: const BoxDecoration(
                      color: EchoTheme.accent,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(4),
                        bottomLeft: Radius.circular(4),
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: widget.isSelected ? 4 : 8,
                      right: 8,
                      top: 6,
                      bottom: 6,
                    ),
                    child: Row(
                      children: [
                        // Avatar
                        Stack(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: conv.isGroup
                                  ? EchoTheme.accent
                                  : _avatarColor(displayName),
                              child: conv.isGroup
                                  ? const Icon(Icons.tag,
                                      size: 16, color: Colors.white)
                                  : Text(
                                      displayName.isNotEmpty
                                          ? displayName[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                            if (!conv.isGroup)
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
                                      color: widget.isSelected
                                          ? EchoTheme.activeBg
                                          : EchoTheme.panelBg,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 10),
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
                                            : EchoTheme.textSecondary,
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
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        snippet,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: EchoTheme.textMuted,
                                          fontWeight: hasUnread
                                              ? FontWeight.w500
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                    if (hasUnread)
                                      Container(
                                        margin: const EdgeInsets.only(left: 4),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: EchoTheme.accent,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          conv.unreadCount > 99
                                              ? '99+'
                                              : conv.unreadCount.toString(),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
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
              ],
            ),
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
