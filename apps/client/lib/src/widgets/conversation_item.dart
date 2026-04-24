import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart';

/// Return the dot color for a peer presence status.
Color presenceStatusDotColor(
  BuildContext context,
  String presenceStatus,
  bool isOnline,
) {
  if (!isOnline) return const Color(0xFF6B6B6F);
  return switch (presenceStatus) {
    'online' => EchoTheme.online,
    'away' => EchoTheme.warning,
    'dnd' => EchoTheme.danger,
    'invisible' => const Color(0xFF6B6B6F),
    _ => const Color(0xFF6B6B6F),
  };
}

class ConversationItem extends StatefulWidget {
  final Conversation conversation;
  final String myUserId;
  final bool isSelected;
  final bool isPinned;
  final bool isPeerOnline;

  /// The peer's presence status: "online", "away", "dnd", "invisible", "offline".
  /// Defaults to "online" when not provided (backward compat).
  final String peerPresenceStatus;

  final String? peerAvatarUrl;
  final String? groupIconUrl;
  final String timestamp;
  final VoidCallback onTap;
  final void Function(Offset position)? onContextMenu;

  /// Number of group members (other than the current user) currently online.
  /// Only consulted when [Conversation.isGroup] is true.
  final int onlineMemberCount;

  const ConversationItem({
    super.key,
    required this.conversation,
    required this.myUserId,
    required this.isSelected,
    required this.isPinned,
    required this.isPeerOnline,
    this.peerPresenceStatus = 'online',
    this.peerAvatarUrl,
    this.groupIconUrl,
    required this.timestamp,
    required this.onTap,
    this.onContextMenu,
    this.onlineMemberCount = 0,
  });

  @override
  State<ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends State<ConversationItem> {
  bool _isHovered = false;
  String? _draft;

  static const _draftKeyPrefix = 'chat_draft_';

  /// Cached SharedPreferences instance to avoid async getInstance() per render.
  static SharedPreferences? _prefsCache;

  @override
  void initState() {
    super.initState();
    _loadDraft();
  }

  @override
  void didUpdateWidget(covariant ConversationItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id != widget.conversation.id) {
      _loadDraft();
    }
  }

  Future<void> _loadDraft() async {
    _prefsCache ??= await SharedPreferences.getInstance();
    final raw = _prefsCache!.getString(
      '$_draftKeyPrefix${widget.conversation.id}',
    );
    if (!mounted) return;
    final draft = raw?.trim().isNotEmpty == true ? raw!.trim() : null;
    if (draft != _draft) setState(() => _draft = draft);
  }

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
    // DMs: the conversation header already shows the peer's name, so
    // prefixing the message with the sender is redundant.
    if (!conv.isGroup) return snippet;
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

    return Semantics(
      label: 'Conversation with $displayName',
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onHover: (hovered) => setState(() => _isHovered = hovered),
          onTap: widget.onTap,
          onSecondaryTapUp: (details) {
            widget.onContextMenu?.call(details.globalPosition);
          },
          onLongPress: _enableLongPressMenu
              ? () {
                  // globalPosition not available on InkWell.onLongPress;
                  // fall back to the widget's own render box center.
                  final box = context.findRenderObject() as RenderBox?;
                  if (box != null) {
                    final center = box.localToGlobal(
                      Offset(box.size.width / 2, box.size.height / 2),
                    );
                    widget.onContextMenu?.call(center);
                  }
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
          imageUrl: conv.isGroup ? widget.groupIconUrl : widget.peerAvatarUrl,
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
                color: presenceStatusDotColor(
                  context,
                  widget.peerPresenceStatus,
                  widget.isPeerOnline,
                ),
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
    // On desktop (non-web, non-mobile), show a ... button on hover so users
    // who don't right-click can still discover the context menu.
    final showMoreButton =
        _isHovered &&
        widget.onContextMenu != null &&
        !kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS;

    final conv = widget.conversation;
    final showGroupOnline = conv.isGroup && widget.onlineMemberCount > 0;

    return Row(
      children: [
        if (widget.isPinned)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.push_pin, size: 12, color: context.textMuted),
          ),
        Flexible(
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
        if (showGroupOnline)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: EchoTheme.online.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: EchoTheme.online,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${widget.onlineMemberCount}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: EchoTheme.online,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const Spacer(),
        if (showMoreButton)
          Semantics(
            label: 'More options for $displayName',
            button: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTapDown: (details) {
                widget.onContextMenu?.call(details.globalPosition);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.more_horiz,
                  size: 16,
                  color: context.textMuted,
                ),
              ),
            ),
          )
        else if (widget.timestamp.isNotEmpty)
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
    final showDraft = _draft != null && !hasUnread;
    final snippetWeight = hasUnread ? FontWeight.w500 : FontWeight.normal;
    return Row(
      children: [
        Expanded(
          child: showDraft
              ? RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    children: [
                      const TextSpan(
                        text: 'Draft: ',
                        style: TextStyle(
                          fontSize: 13,
                          color: EchoTheme.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: _draft,
                        style: TextStyle(
                          fontSize: 13,
                          color: context.textMuted,
                        ),
                      ),
                    ],
                  ),
                )
              : Text(
                  snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.textMuted,
                    fontWeight: snippetWeight,
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
          Semantics(
            label: '${widget.conversation.unreadCount} unread messages',
            child: Container(
              margin: const EdgeInsets.only(left: 8),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: context.accent,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: ExcludeSemantics(
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
            ),
          ),
      ],
    );
  }
}
