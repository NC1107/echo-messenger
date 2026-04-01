import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../theme/echo_theme.dart';

/// Common emojis for the reaction picker.
const reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👎', '🎉'];

/// Regex for detecting URLs in message text.
final _urlRegex = RegExp(r'https?://[^\s]+');

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
      final hour = dt.hour;
      final minute = dt.minute.toString().padLeft(2, '0');
      final ampm = hour >= 12 ? 'PM' : 'AM';
      final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
      return '$displayHour:$minute $ampm';
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
        icon = Icons.schedule_outlined;
        color = EchoTheme.textMuted;
      case MessageStatus.sent:
        icon = Icons.check_outlined;
        color = EchoTheme.textMuted;
      case MessageStatus.delivered:
        icon = Icons.done_all_outlined;
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
    ];
    final index = userId.hashCode.abs() % colors.length;
    return colors[index];
  }

  /// Build a RichText widget that renders URLs as tappable, underlined links.
  Widget _buildMessageText(String text, {required Color textColor}) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          fontSize: 15,
          color: textColor,
          height: 1.47,
        ),
      );
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      // Text before the URL
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(
            fontSize: 15,
            color: textColor,
            height: 1.47,
          ),
        ));
      }

      // The URL itself
      final url = match.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: const TextStyle(
          fontSize: 15,
          color: EchoTheme.accentHover,
          decoration: TextDecoration.underline,
          decorationColor: EchoTheme.accentHover,
          height: 1.47,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () async {
            final uri = Uri.tryParse(url);
            if (uri != null && await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
      ));

      lastEnd = match.end;
    }

    // Remaining text after last URL
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(
          fontSize: 15,
          color: textColor,
          height: 1.47,
        ),
      ));
    }

    return RichText(
      text: TextSpan(children: spans),
    );
  }

  Widget _buildReactions(List<Reaction> reactions, bool isMine) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    final grouped = <String, List<Reaction>>{};
    for (final r in reactions) {
      grouped.putIfAbsent(r.emoji, () => []).add(r);
    }

    return Padding(
      padding: EdgeInsets.only(
        top: 4,
        left: isMine ? 0 : 36,
        right: isMine ? 0 : 0,
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: isMine ? WrapAlignment.end : WrapAlignment.start,
        children: grouped.entries.map((entry) {
          final hasMyReaction =
              entry.value.any((r) => r.userId == widget.myUserId);
          return InkWell(
            onTap: () {
              widget.onReactionSelect?.call(widget.message, entry.key);
            },
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: hasMyReaction
                    ? EchoTheme.accent.withValues(alpha: 0.2)
                    : EchoTheme.surface,
                borderRadius: BorderRadius.circular(10),
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
    final isMine = msg.isMine;
    final isFailed = msg.status == MessageStatus.failed;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: widget.showHeader ? 8 : 2,
          bottom: 2,
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Row(
                  mainAxisAlignment:
                      isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Avatar for received messages (first in group only)
                    if (!isMine) ...[
                      SizedBox(
                        width: 28,
                        child: widget.showHeader
                            ? CircleAvatar(
                                radius: 14,
                                backgroundColor:
                                    _getUserColor(msg.fromUserId),
                                child: Text(
                                  msg.fromUsername.isNotEmpty
                                      ? msg.fromUsername[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // Bubble
                    Flexible(
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.65,
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isFailed
                              ? EchoTheme.danger.withValues(alpha: 0.2)
                              : isMine
                                  ? EchoTheme.sentBubble
                                  : EchoTheme.recvBubble,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft:
                                Radius.circular(!isMine ? 4 : 16),
                            bottomRight:
                                Radius.circular(isMine ? 4 : 16),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Sender name for group received messages
                            if (!isMine && widget.showHeader)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  msg.fromUsername,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _getUserColor(msg.fromUserId),
                                  ),
                                ),
                              ),
                            // Message text with URL detection
                            _buildMessageText(
                              msg.content,
                              textColor: isFailed
                                  ? EchoTheme.danger
                                  : isMine
                                      ? Colors.white
                                      : EchoTheme.textPrimary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // Hover action buttons
                if (_isHovered)
                  Positioned(
                    top: 0,
                    right: isMine ? null : 0,
                    left: isMine ? 0 : null,
                    child: Container(
                      decoration: BoxDecoration(
                        color: EchoTheme.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: EchoTheme.border,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _HoverActionButton(
                            icon: Icons.add_reaction_outlined,
                            tooltip: 'React',
                            onPressed: () =>
                                widget.onReactionTap?.call(msg),
                          ),
                          _HoverActionButton(
                            icon: Icons.reply_outlined,
                            tooltip: 'Reply',
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            // Timestamp (only on last in group)
            if (widget.isLastInGroup)
              Padding(
                padding: EdgeInsets.only(
                  top: 4,
                  left: isMine ? 0 : 36,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment:
                      isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
                  children: [
                    Text(
                      _formatTimestamp(msg.timestamp),
                      style: const TextStyle(
                        fontSize: 11,
                        color: EchoTheme.textMuted,
                      ),
                    ),
                    if (isMine) _buildStatusIcon(msg.status),
                  ],
                ),
              ),
            _buildReactions(msg.reactions, isMine),
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
          child: Icon(icon, size: 16, color: EchoTheme.textSecondary),
        ),
      ),
    );
  }
}
