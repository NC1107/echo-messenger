import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../theme/echo_theme.dart';

/// Common emojis for the reaction picker.
const reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👎', '🎉'];

class MessageItem extends StatefulWidget {
  final ChatMessage message;
  final bool showHeader;
  final bool isLastInGroup;
  final String myUserId;
  final void Function(ChatMessage message)? onReactionTap;
  final void Function(ChatMessage message, String emoji)? onReactionSelect;

  const MessageItem({
    super.key,
    required this.message,
    required this.showHeader,
    required this.isLastInGroup,
    required this.myUserId,
    this.onReactionTap,
    this.onReactionSelect,
  });

  @override
  State<MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<MessageItem> {
  bool _isHovered = false;

  String _formatTimestamp(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final messageDay = DateTime(dt.year, dt.month, dt.day);
      final diff = today.difference(messageDay).inDays;

      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      final time = '$hour:$minute';

      if (diff == 0) {
        return 'Today at $time';
      } else if (diff == 1) {
        return 'Yesterday at $time';
      } else {
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        return '${months[dt.month - 1]} ${dt.day}, ${dt.year} at $time';
      }
    } catch (_) {
      return '';
    }
  }

  String _formatShortTime(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '';
    }
  }

  Widget _buildStatusIcon(MessageStatus? status) {
    if (status == null) return const SizedBox.shrink();
    IconData icon;
    Color color;
    switch (status) {
      case MessageStatus.sending:
        icon = Icons.access_time;
        color = EchoTheme.textMuted;
      case MessageStatus.sent:
        icon = Icons.check;
        color = EchoTheme.textMuted;
      case MessageStatus.delivered:
        icon = Icons.done_all;
        color = EchoTheme.online;
      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = EchoTheme.danger;
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Icon(icon, size: 12, color: color),
    );
  }

  Color _getUserColor(String userId) {
    final colors = [
      const Color(0xFFE06666),
      const Color(0xFFF6B05C),
      const Color(0xFF57D28F),
      const Color(0xFF5DADE2),
      const Color(0xFFAF7AC5),
      const Color(0xFFEB984E),
      const Color(0xFF5DADE2),
      const Color(0xFFE74C3C),
    ];
    final index = userId.hashCode.abs() % colors.length;
    return colors[index];
  }

  Widget _buildReactions(List<Reaction> reactions) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    final grouped = <String, List<Reaction>>{};
    for (final r in reactions) {
      grouped.putIfAbsent(r.emoji, () => []).add(r);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 48, top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: grouped.entries.map((entry) {
          final hasMyReaction =
              entry.value.any((r) => r.userId == widget.myUserId);
          return InkWell(
            onTap: () {
              widget.onReactionSelect?.call(widget.message, entry.key);
            },
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: hasMyReaction
                    ? EchoTheme.accent.withValues(alpha: 0.3)
                    : EchoTheme.inputBg,
                borderRadius: BorderRadius.circular(4),
                border: hasMyReaction
                    ? Border.all(color: EchoTheme.accent, width: 1)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(entry.key, style: const TextStyle(fontSize: 14)),
                  if (entry.value.length > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '${entry.value.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: hasMyReaction
                            ? EchoTheme.accent
                            : EchoTheme.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isFailed = msg.status == MessageStatus.failed;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        color: _isHovered ? EchoTheme.hoverBg : Colors.transparent,
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: widget.showHeader ? 8 : 1,
          bottom: 1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Avatar column (32px wide + 16px gap)
                    SizedBox(
                      width: 40,
                      child: widget.showHeader
                          ? CircleAvatar(
                              radius: 16,
                              backgroundColor:
                                  _getUserColor(msg.fromUserId),
                              child: Text(
                                msg.fromUsername.isNotEmpty
                                    ? msg.fromUsername[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                          : _isHovered
                              ? SizedBox(
                                  width: 40,
                                  child: Center(
                                    child: Text(
                                      _formatShortTime(msg.timestamp),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: EchoTheme.textMuted,
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox(width: 40),
                    ),
                    const SizedBox(width: 8),
                    // Content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.showHeader)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Row(
                                children: [
                                  Text(
                                    msg.isMine
                                        ? 'You'
                                        : msg.fromUsername,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          _getUserColor(msg.fromUserId),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _formatTimestamp(msg.timestamp),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: EchoTheme.textMuted,
                                    ),
                                  ),
                                  if (msg.isMine)
                                    _buildStatusIcon(msg.status),
                                ],
                              ),
                            ),
                          Text(
                            msg.content,
                            style: TextStyle(
                              fontSize: 14,
                              color: isFailed
                                  ? EchoTheme.danger
                                  : EchoTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Hover action buttons
                if (_isHovered)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: EchoTheme.panelBg,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: EchoTheme.divider,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _HoverActionButton(
                            icon: Icons.add_reaction_outlined,
                            tooltip: 'Add Reaction',
                            onPressed: () =>
                                widget.onReactionTap?.call(msg),
                          ),
                          _HoverActionButton(
                            icon: Icons.reply,
                            tooltip: 'Reply',
                            onPressed: () {},
                          ),
                          _HoverActionButton(
                            icon: Icons.more_horiz,
                            tooltip: 'More',
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            _buildReactions(msg.reactions),
          ],
        ),
      ),
    );
  }
}

class _HoverActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _HoverActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: EchoTheme.textSecondary),
        ),
      ),
    );
  }
}
