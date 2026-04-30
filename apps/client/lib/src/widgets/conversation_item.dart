import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart' show MessageStatus;
import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart';

/// Fixed height of a single conversation list item (excluding margin).
const double kConversationItemHeight = 68.0;

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

/// Compose the screen-reader announcement for a conversation row (#631).
///
/// Order: name -> unread count -> muted -> last message snippet. Exposed
/// at top level so widget tests can lock the contract without reaching
/// into the private state class.
String composeConversationItemSemanticsLabel({
  required String displayName,
  required int unreadCount,
  required bool muted,
  required String? snippet,
}) {
  final buf = StringBuffer('Conversation with $displayName');
  if (unreadCount > 0) {
    buf.write(', $unreadCount unread');
  }
  if (muted) {
    buf.write(', muted');
  }
  if (snippet != null && snippet.isNotEmpty) {
    buf.write('. Last message: $snippet');
  }
  return buf.toString();
}

class ConversationItem extends ConsumerStatefulWidget {
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
  ConsumerState<ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends ConsumerState<ConversationItem> {
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

  /// Long-press bottom sheet with the per-conversation mute toggle.
  /// Mobile-only — desktop users get the right-click popup menu instead.
  void _showMuteSheet() {
    final conv = widget.conversation;
    final displayName = conv.displayName(widget.myUserId);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text(
                    displayName,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                ),
                Divider(color: context.border, height: 8),
                Consumer(
                  builder: (ctx, sheetRef, _) {
                    final live = sheetRef
                        .watch(conversationsProvider)
                        .conversations
                        .where((c) => c.id == conv.id)
                        .firstOrNull;
                    final currentMuted = live?.isMuted ?? conv.isMuted;
                    return SwitchListTile(
                      value: currentMuted,
                      onChanged: (value) async {
                        Navigator.of(sheetContext).pop();
                        final success = await ref
                            .read(conversationsProvider.notifier)
                            .setMuted(conv.id, value);
                        if (!success && mounted) {
                          ToastService.show(
                            context,
                            'Failed to update mute settings',
                            type: ToastType.error,
                          );
                        }
                      },
                      title: Text(
                        'Mute notifications',
                        style: GoogleFonts.inter(
                          color: context.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                      secondary: Icon(
                        currentMuted
                            ? Icons.notifications_off_outlined
                            : Icons.notifications_outlined,
                        color: context.textSecondary,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
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
      // The DM context already implies encryption; saying "encrypted" here
      // looks like an error state. Use a neutral placeholder instead.
      return '[E2E] Message';
    }
    return snippet;
  }

  String? _applyMediaLabel(String? snippet) {
    if (snippet == null) return null;
    if (RegExp(r'^\[img:.+\]$').hasMatch(snippet)) {
      return '\u{1F4F7} Photo';
    }
    if (RegExp(r'^\[video:.+\]$').hasMatch(snippet)) {
      return '\u{1F3AC} Video';
    }
    if (RegExp(r'^\[file:.+\]$').hasMatch(snippet)) {
      return '\u{1F4CE} File';
    }
    if (RegExp(r'^\[voice:.+\]$').hasMatch(snippet)) {
      return '\u{1F3A4} Voice message';
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
      label: composeConversationItemSemanticsLabel(
        displayName: displayName,
        unreadCount: conv.unreadCount,
        muted: conv.isMuted,
        snippet: snippet,
      ),
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          focusColor: context.accentLight,
          onHover: (hovered) => setState(() => _isHovered = hovered),
          onTap: widget.onTap,
          onSecondaryTapUp: (details) {
            widget.onContextMenu?.call(details.globalPosition);
          },
          onLongPress: _enableLongPressMenu ? _showMuteSheet : null,
          child: Container(
            height: kConversationItemHeight,
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              color: _resolveBackgroundColor(context),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            // Visual children re-announce muted/unread/timestamp via
            // their own Semantics nodes; suppress those so the composed
            // outer label is the single announcement (#631).
            child: ExcludeSemantics(
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
    final peer = conv.isGroup
        ? null
        : conv.members.where((m) => m.userId != widget.myUserId).firstOrNull;
    final statusText = peer?.statusText;

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildNameRow(context, displayName, hasUnread),
          if (statusText != null && statusText.isNotEmpty) ...[
            const SizedBox(height: 1),
            Text(
              statusText,
              style: GoogleFonts.inter(fontSize: 11, color: context.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ] else if (snippet != null) ...[
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

    // Right side: timestamp or hover-action button. Natural width (no fixed
    // SizedBox) so the expanded name fills exactly the remaining space and
    // the timestamp sits flush at the right edge without a "floating" gap.
    final Widget rightSlot;
    if (showMoreButton) {
      rightSlot = Semantics(
        label: 'More options for $displayName',
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTapDown: (details) {
            widget.onContextMenu?.call(details.globalPosition);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(Icons.more_horiz, size: 16, color: context.textMuted),
          ),
        ),
      );
    } else if (widget.timestamp.isNotEmpty) {
      // If the conversation's latest message is one we sent, show a Signal-
      // style status tick next to the timestamp (#507). Falls back silently
      // when local chat state hasn't loaded the conversation yet.
      final tick = _buildOwnStatusTick(context);
      rightSlot = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tick != null) ...[tick, const SizedBox(width: 4)],
          Text(
            widget.timestamp,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: hasUnread ? context.accent : context.textMuted,
            ),
          ),
        ],
      );
    } else {
      rightSlot = const SizedBox.shrink();
    }

    return Row(
      children: [
        if (widget.isPinned)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.push_pin, size: 16, color: context.textMuted),
          ),
        // Expanded forces the name to fill all remaining space so the right
        // side (badge + timestamp) is naturally anchored at the row edge.
        Expanded(
          child: Text(
            displayName,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
              color: context.textPrimary,
            ),
          ),
        ),
        if (showGroupOnline)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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
        Padding(padding: const EdgeInsets.only(left: 6), child: rightSlot),
      ],
    );
  }

  /// Signal-style read indicator for the last message in this conversation,
  /// shown only when *we* sent that message (#507).
  ///
  /// Returns null when there is no local chat state for this conversation
  /// (cold start before chat is opened) — the conv list falls back to its
  /// pre-existing layout in that case.
  Widget? _buildOwnStatusTick(BuildContext context) {
    final conv = widget.conversation;
    final messages = ref.watch(chatProvider).messagesForConversation(conv.id);
    final last = messages.isEmpty ? null : messages.last;
    if (last == null || last.fromUserId != widget.myUserId) return null;

    final (icon, color) = switch (last.status) {
      MessageStatus.sending ||
      MessageStatus.sent => (Icons.done, context.textMuted),
      MessageStatus.delivered => (Icons.done_all, context.textMuted),
      MessageStatus.read => (Icons.done_all, context.accent),
      MessageStatus.failed => (Icons.error_outline, EchoTheme.danger),
    };
    return Icon(icon, size: 14, color: color);
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
                      TextSpan(
                        text: 'Draft: ',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: EchoTheme.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: _draft,
                        style: GoogleFonts.inter(
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
                  style: GoogleFonts.inter(
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
              size: 16,
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
                color: conv.isMuted ? context.surfaceHover : context.accent,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: ExcludeSemantics(
                child: Text(
                  widget.conversation.unreadCount > 99
                      ? '99+'
                      : '${widget.conversation.unreadCount}',
                  style: GoogleFonts.inter(
                    color: conv.isMuted
                        ? context.textMuted
                        : Theme.of(context).colorScheme.onPrimary,
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
