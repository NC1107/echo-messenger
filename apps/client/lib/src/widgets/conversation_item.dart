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

  /// Resolve the display snippet from the last message, applying
  /// encryption placeholders and media labels.
  String? _resolveSnippet() {
    final conv = widget.conversation;
    String? snippet = conv.lastMessage;

    snippet = _maskEncryptedSnippet(snippet);
    snippet = _applyMediaLabel(snippet);
    snippet = _prependSenderLabel(snippet, conv);
    if (snippet != null) snippet = _stripMarkdown(snippet);

    return snippet;
  }

  /// Remove common markdown syntax from the snippet preview while keeping
  /// the underlying text content.
  String _stripMarkdown(String text) {
    // Remove code block markers (```)
    text = text.replaceAll('```', '');
    // Remove bold markers (**)
    text = text.replaceAll('**', '');
    // Remove italic markers (*) -- single asterisks only since ** already gone
    text = text.replaceAll('*', '');
    // Remove inline code markers (`)
    text = text.replaceAll('`', '');
    return text;
  }

  String? _maskEncryptedSnippet(String? snippet) {
    if (snippet != null &&
        (snippet.startsWith('[Could not decrypt]') ||
            snippet.startsWith('[Encrypted'))) {
      return '\u{1F512} Encrypted message';
    }
    return snippet;
  }

  String? _applyMediaLabel(String? snippet) {
    if (snippet == null) return null;
    if (RegExp(r'^\[img:.+\]$').hasMatch(snippet)) {
      return '\u{1F5BC} Image';
    }
    if (RegExp(r'^\[video:.+\]$').hasMatch(snippet)) {
      return '\u{1F3AC} Video';
    }
    if (RegExp(r'^\[file:.+\]$').hasMatch(snippet)) {
      return '\u{1F4CE} File';
    }
    return snippet;
  }

  String? _prependSenderLabel(String? snippet, Conversation conv) {
    if (snippet == null || conv.lastMessageSender == null) return snippet;
    final myMember = conv.members
        .where((m) => m.userId == widget.myUserId)
        .firstOrNull;
    final isMe = myMember?.username == conv.lastMessageSender;
    final senderLabel = isMe ? 'You' : conv.lastMessageSender!;
    return '$senderLabel: $snippet';
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final displayName = conv.displayName(widget.myUserId);
    final hasUnread = conv.unreadCount > 0;
    final snippet = _resolveSnippet();

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
            color: _resolveBackgroundColor(context),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _buildAvatarStack(context, conv, displayName),
              const SizedBox(width: 12),
              _buildNameAndSnippet(
                context,
                displayName: displayName,
                snippet: snippet,
                hasUnread: hasUnread,
                conv: conv,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _resolveBackgroundColor(BuildContext context) {
    if (widget.isSelected) return context.accentLight;
    if (_isHovered) return context.surfaceHover;
    return Colors.transparent;
  }

  Widget _buildAvatarStack(
    BuildContext context,
    Conversation conv,
    String displayName,
  ) {
    return Stack(
      children: [
        buildAvatar(
          name: displayName,
          radius: 20,
          imageUrl: conv.isGroup ? null : widget.peerAvatarUrl,
          bgColor: conv.isGroup ? groupAvatarColor(displayName) : null,
          fallbackIcon: conv.isGroup
              ? const Icon(Icons.group, size: 18, color: Colors.white)
              : null,
        ),
        if (!conv.isGroup)
          Positioned(
            bottom: 0,
            right: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: widget.isPeerOnline
                    ? EchoTheme.online
                    : context.textMuted.withValues(alpha: 0.4),
                shape: BoxShape.circle,
                border: Border.all(color: context.sidebarBg, width: 2),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildNameAndSnippet(
    BuildContext context, {
    required String displayName,
    required String? snippet,
    required bool hasUnread,
    required Conversation conv,
  }) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildNameRow(context, displayName, hasUnread),
          if (snippet != null) ...[
            const SizedBox(height: 4),
            _buildSnippetRow(context, snippet, hasUnread, conv),
          ],
        ],
      ),
    );
  }

  Widget _buildNameRow(
    BuildContext context,
    String displayName,
    bool hasUnread,
  ) {
    return Row(
      children: [
        if (widget.isPinned)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.push_pin, size: 12, color: context.textMuted),
          ),
        Expanded(
          child: Text(
            displayName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
              color: context.textPrimary,
            ),
          ),
        ),
        if (widget.timestamp.isNotEmpty)
          Text(
            widget.timestamp,
            style: TextStyle(
              fontSize: 11,
              color: hasUnread ? context.accent : context.textMuted,
            ),
          ),
      ],
    );
  }

  Widget _buildSnippetRow(
    BuildContext context,
    String snippet,
    bool hasUnread,
    Conversation conv,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(
            snippet,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: context.textMuted,
              fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
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
            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: context.accent,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Text(
              widget.conversation.unreadCount > 99
                  ? '99+'
                  : '${widget.conversation.unreadCount}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
      ],
    );
  }
}
