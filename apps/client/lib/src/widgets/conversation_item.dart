import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart';

class ConversationItem extends StatefulWidget {
  final Conversation conversation;
  final String myUserId;
  final bool isSelected;
  final bool isPinned;
  final bool isPeerOnline;
  final String? peerAvatarUrl;
  final String timestamp;
  final VoidCallback onTap;
  final void Function(Offset position)? onContextMenu;

  const ConversationItem({
    super.key,
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
  State<ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends State<ConversationItem> {
  bool _isHovered = false;

  bool get _enableLongPressMenu {
    if (kIsWeb) {
      return false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => true,
      TargetPlatform.iOS => true,
      _ => false,
    };
  }

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
    // Show friendly labels for media markers
    if (snippet != null) {
      if (RegExp(r'^\[img:.+\]$').hasMatch(snippet)) {
        snippet = '\u{1F5BC} Image';
      } else if (RegExp(r'^\[video:.+\]$').hasMatch(snippet)) {
        snippet = '\u{1F3AC} Video';
      } else if (RegExp(r'^\[file:.+\]$').hasMatch(snippet)) {
        snippet = '\u{1F4CE} File';
      }
    }
    if (snippet != null && conv.lastMessageSender != null) {
      // Find if sender is "me" by checking if any member with myUserId has this username
      final myMember = conv.members
          .where((m) => m.userId == widget.myUserId)
          .firstOrNull;
      final isMe = myMember?.username == conv.lastMessageSender;
      final senderLabel = isMe ? 'You' : conv.lastMessageSender!;
      snippet = '$senderLabel: $snippet';
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: (details) {
          widget.onContextMenu?.call(details.globalPosition);
        },
        onLongPressStart: _enableLongPressMenu
            ? (details) {
                widget.onContextMenu?.call(details.globalPosition);
              }
            : null,
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
                          if (conv.isMuted)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(
                                Icons.notifications_off_outlined,
                                size: 14,
                                color: context.textMuted,
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
