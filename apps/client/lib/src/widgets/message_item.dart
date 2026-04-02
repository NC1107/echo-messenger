import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';
import 'conversation_panel.dart' show buildAvatar, avatarColor;

/// Common emojis for the reaction picker.
const reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👎', '🎉'];

/// Regex for detecting URLs in message text.
final _urlRegex = RegExp(r'https?://[^\s]+');

/// Regex for detecting image markers: [img:URL]
final _imgRegex = RegExp(r'^\[img:(.+)\]$');

class MessageItem extends StatefulWidget {
  final ChatMessage message;
  final bool showHeader;
  final bool isLastInGroup;
  final String myUserId;
  final void Function(ChatMessage message)? onReactionTap;
  final void Function(ChatMessage message, String emoji)? onReactionSelect;
  final void Function(ChatMessage message)? onDelete;
  final void Function(ChatMessage message)? onEdit;
  final void Function(String userId)? onAvatarTap;

  /// Server URL for resolving relative image paths.
  final String? serverUrl;

  /// Auth token for authenticated image requests.
  final String? authToken;

  /// Avatar URL path for the message sender (relative, e.g. /api/users/.../avatar).
  final String? senderAvatarUrl;

  const MessageItem({
    super.key,
    required this.message,
    required this.showHeader,
    required this.isLastInGroup,
    required this.myUserId,
    this.onReactionTap,
    this.onReactionSelect,
    this.onDelete,
    this.onEdit,
    this.onAvatarTap,
    this.serverUrl,
    this.authToken,
    this.senderAvatarUrl,
  });

  @override
  State<MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<MessageItem> {
  bool _isHovered = false;

  Widget _buildStatusIcon(MessageStatus? status) {
    if (status == null) return const SizedBox.shrink();
    IconData icon;
    Color color;
    switch (status) {
      case MessageStatus.sending:
        icon = Icons.schedule_outlined;
        color = context.textMuted;
      case MessageStatus.sent:
        icon = Icons.check_outlined;
        color = context.textMuted;
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

  /// Consistent color for a username -- matches sidebar avatar colors.
  Color _getUserColor(String userId) {
    final name = widget.message.fromUsername;
    return avatarColor(name);
  }

  /// Check if the message content is an image marker and build the image widget.
  Widget? _buildImageContent(String content, {required bool isMine}) {
    final match = _imgRegex.firstMatch(content);
    if (match == null) return null;

    final url = match.group(1)!;
    final fullUrl = url.startsWith('/') ? '${widget.serverUrl ?? ""}$url' : url;

    final headers = <String, String>{};
    if (widget.authToken != null && widget.authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${widget.authToken}';
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        fullUrl,
        width: 300,
        fit: BoxFit.cover,
        headers: headers,
        errorBuilder: (_, _, _) => Container(
          width: 300,
          height: 80,
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              '[Image failed to load]',
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  /// Build a RichText widget that renders URLs as tappable, underlined links.
  Widget _buildMessageText(String text, {required Color textColor}) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(
        text,
        style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
      );
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      // Text before the URL
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastEnd, match.start),
            style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
          ),
        );
      }

      // The URL itself
      final url = match.group(0)!;
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(
            fontSize: 15,
            color: context.accentHover,
            decoration: TextDecoration.underline,
            decorationColor: context.accentHover,
            height: 1.47,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () async {
              final uri = Uri.tryParse(url);
              if (uri != null && await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
        ),
      );

      lastEnd = match.end;
    }

    // Remaining text after last URL
    if (lastEnd < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(lastEnd),
          style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
        ),
      );
    }

    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildReactionPill(List<Reaction> reactions, bool isMine) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Collect unique emojis preserving order of first appearance.
    final seen = <String>{};
    final uniqueEmojis = <String>[];
    for (final r in reactions) {
      if (seen.add(r.emoji)) uniqueEmojis.add(r.emoji);
    }

    final totalCount = reactions.length;

    return GestureDetector(
      onTap: () => widget.onReactionTap?.call(widget.message),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in uniqueEmojis)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(emoji, style: const TextStyle(fontSize: 14)),
              ),
            if (totalCount > 1) ...[
              const SizedBox(width: 2),
              Text(
                '$totalCount',
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isMine = msg.isMine;
    final isFailed = msg.status == MessageStatus.failed;

    // Check if message is an image
    final imageWidget = _buildImageContent(msg.content, isMine: isMine);

    final hasReactions = msg.reactions.isNotEmpty;
    final reactionPill = _buildReactionPill(msg.reactions, isMine);

    // The bubble widget
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.65,
      ),
      padding: imageWidget != null
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isFailed
            ? EchoTheme.danger.withValues(alpha: 0.2)
            : isMine
            ? context.sentBubble
            : context.recvBubble,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(!isMine ? 4 : 16),
          bottomRight: Radius.circular(isMine ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sender name for group received messages
          if (!isMine && widget.showHeader)
            Padding(
              padding: EdgeInsets.only(
                bottom: 4,
                left: imageWidget != null ? 8 : 0,
              ),
              child: Text(
                msg.fromUsername,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _getUserColor(msg.fromUserId),
                ),
              ),
            ),
          // Image or text content
          if (imageWidget != null)
            imageWidget
          else
            _buildMessageText(
              msg.content,
              textColor: isFailed
                  ? EchoTheme.danger
                  : isMine
                  ? Colors.white
                  : context.textPrimary,
            ),
        ],
      ),
    );

    // Bubble with reaction pill overlapping bottom via Stack
    Widget bubbleWithReactions;
    if (hasReactions) {
      bubbleWithReactions = Stack(
        clipBehavior: Clip.none,
        children: [
          // Add bottom padding so the pill has room to overlap
          Padding(padding: const EdgeInsets.only(bottom: 14), child: bubble),
          // Reaction pill overlapping bottom of the bubble
          Positioned(
            bottom: 0,
            left: isMine ? null : 8,
            right: isMine ? 8 : null,
            child: reactionPill,
          ),
        ],
      );
    } else {
      bubbleWithReactions = bubble;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onLongPress: !hasReactions
            ? () => widget.onReactionTap?.call(msg)
            : null,
        child: Container(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: widget.showHeader ? 8 : 2,
            bottom: hasReactions ? 4 : 2,
          ),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Row(
                    mainAxisAlignment: isMine
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Avatar for received messages (first in group only)
                      if (!isMine) ...[
                        GestureDetector(
                          onTap: widget.onAvatarTap != null
                              ? () => widget.onAvatarTap!(msg.fromUserId)
                              : null,
                          child: SizedBox(
                            width: 28,
                            child: widget.showHeader
                                ? buildAvatar(
                                    name: msg.fromUsername,
                                    radius: 14,
                                    bgColor: _getUserColor(msg.fromUserId),
                                    imageUrl: widget.senderAvatarUrl != null
                                        ? '${widget.serverUrl ?? ""}${widget.senderAvatarUrl}'
                                        : null,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // Bubble with reactions
                      Flexible(child: bubbleWithReactions),
                    ],
                  ),
                  // Hover action: show reaction picker for messages without
                  // reactions (messages with reactions use the pill tap instead)
                  if (_isHovered && !hasReactions)
                    Positioned(
                      top: 0,
                      right: isMine ? null : 0,
                      left: isMine ? 0 : null,
                      child: Container(
                        decoration: BoxDecoration(
                          color: context.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: context.border, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _HoverActionButton(
                              icon: Icons.copy_outlined,
                              tooltip: 'Copy',
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: msg.content),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Copied to clipboard'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                            ),
                            _HoverActionButton(
                              icon: Icons.add_reaction_outlined,
                              tooltip: 'React',
                              onPressed: () => widget.onReactionTap?.call(msg),
                            ),
                            if (isMine && widget.onEdit != null)
                              _HoverActionButton(
                                icon: Icons.edit_outlined,
                                tooltip: 'Edit',
                                onPressed: () => widget.onEdit?.call(msg),
                              ),
                            if (isMine && widget.onDelete != null)
                              _HoverActionButton(
                                icon: Icons.delete_outlined,
                                tooltip: 'Delete',
                                onPressed: () => widget.onDelete?.call(msg),
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
                  padding: EdgeInsets.only(top: 4, left: isMine ? 0 : 36),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: isMine
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    children: [
                      Text(
                        formatMessageTimestamp(msg.timestamp),
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textMuted,
                        ),
                      ),
                      if (msg.isEncrypted)
                        Padding(
                          padding: const EdgeInsets.only(left: 3),
                          child: Icon(
                            Icons.lock,
                            size: 10,
                            color: EchoTheme.online,
                          ),
                        ),
                      if (msg.editedAt != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            '(edited)',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: context.textMuted,
                            ),
                          ),
                        ),
                      if (isMine) _buildStatusIcon(msg.status),
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
          child: Icon(icon, size: 16, color: context.textSecondary),
        ),
      ),
    );
  }
}
