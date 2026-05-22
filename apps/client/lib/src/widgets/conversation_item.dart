import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart' show ChatMessage, MessageStatus;
import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/theme_provider.dart' show UIDensity, uiDensityProvider;
import '../theme/echo_theme.dart';
import '../theme/motion_tokens.dart';
import '../utils/crypto_utils.dart';
import '../utils/presence.dart';
import 'avatar_utils.dart';
// Stack + Positioned (active edge bar overlay) come from material.dart.

/// Fixed height of a single conversation list item in the normal density
/// tier (UX roadmap Phase 2).
const double kConversationItemHeight = 68.0;

/// Tighter height for the compact (Discord-style) density tier.
/// Bumped from 52px to 56px to maintain buffer above 56px bottom tab bar.
const double kConversationItemHeightCompact = 56.0;

/// Roomier height for the cozy density tier — power users who want
/// breathing room on large displays.
const double kConversationItemHeightCozy = 84.0;

/// Looks up the conversation row height for a given [density]. Used by
/// `ConversationPanel` and tests so the list-level geometry stays in sync
/// with `ConversationItem`'s own sizing.
double conversationItemHeightFor(UIDensity density) => switch (density) {
  UIDensity.cozy => kConversationItemHeightCozy,
  UIDensity.normal => kConversationItemHeight,
  UIDensity.compact => kConversationItemHeightCompact,
};

/// Compose the screen-reader announcement for a conversation row (#631).
///
/// Order: name -> mention -> unread count -> muted -> last message snippet.
/// Mention is announced first because it implies the user has an
/// explicit @-callout waiting; unread count alone doesn't.
/// Exposed at top level so widget tests can lock the contract without
/// reaching into the private state class.
String composeConversationItemSemanticsLabel({
  required String displayName,
  required int unreadCount,
  required bool muted,
  required String? snippet,
  int mentionCount = 0,
}) {
  final buf = StringBuffer('Conversation with $displayName');
  if (mentionCount > 0) {
    buf.write(', mentioned');
  }
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

  /// Called when the user picks "Pin" or "Unpin" from the long-press sheet.
  /// The parent is responsible for toggling the pinned state.
  final VoidCallback? onTogglePin;

  /// Called when the user picks "Leave" (group) or "Delete" (DM) from the
  /// long-press sheet.
  final VoidCallback? onLeave;

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
    this.onTogglePin,
    this.onLeave,
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

  /// Resolve the display snippet from the last message, applying
  /// encryption placeholders and media labels.
  String? _resolveSnippet() {
    final conv = widget.conversation;
    String? snippet = conv.lastMessage;

    // System sentinels (e.g. `__system__:member_joined:UUID:USERNAME`) must
    // be rendered as the friendly event line, not the raw sentinel and not
    // with a "You: " sender prefix. They never come through the WS preview
    // path — only the HTTP last_msg_cte fetch surfaces them — so this is the
    // only place the sidebar gets to translate them.
    if (snippet != null && snippet.startsWith('__system__:')) {
      final translated = ChatMessage.translateSystemSentinel(
        snippet,
        myUserId: widget.myUserId,
      );
      if (translated != null) return translated;
    }

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
    if (snippet == null) return null;
    // Normalise all encrypted-looking previews to a friendly placeholder.
    // Anything starting with a "[Could not decrypt..." / "[Could not verify
    // sender]" / "[Encrypted" / "[E2E]" bracketed sentinel is a protocol
    // status string that should never read like a real message in the
    // sidebar. We also catch raw GRP1:/GRP2: ciphertext + base64-shaped
    // blobs that slipped past the WS decrypt path (missing key envelope,
    // sender device not on file yet).
    if (snippet.startsWith('[Could not decrypt') ||
        snippet.startsWith('[Could not verify sender') ||
        snippet.startsWith('[Encrypted') ||
        snippet.startsWith('[E2E]') ||
        looksEncrypted(snippet)) {
      return '[Encrypted]';
    }
    return snippet;
  }

  String? _applyMediaLabel(String? snippet) {
    if (snippet == null) return null;
    // Match a leading [kind:url] marker, optionally followed by a newline and
    // a caption (the seed scripts emit `[img:URL]\ncaption` for captioned
    // attachments).  The previous `^\[img:.+\]$` regex only matched bare
    // markers, so captioned messages leaked the raw `[img:...]` text into
    // the conversation preview (#prod-2026-05-08).
    final match = RegExp(
      r'^\[(img|video|file|voice):[^\]]+\]\s*\n?\s*',
    ).firstMatch(snippet);
    if (match == null) return snippet;
    final kind = match.group(1)!;
    final caption = snippet.substring(match.end).trim();
    const icons = {
      'img': '\u{1F4F7}',
      'video': '\u{1F3AC}',
      'file': '\u{1F4CE}',
      'voice': '\u{1F3A4}',
    };
    const fallbacks = {
      'img': 'Photo',
      'video': 'Video',
      'file': 'File',
      'voice': 'Voice message',
    };
    final icon = icons[kind] ?? '';
    return caption.isEmpty ? '$icon ${fallbacks[kind]!}' : '$icon $caption';
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
    final density = ref.watch(uiDensityProvider);
    final isCompact = density == UIDensity.compact;
    final isCozy = density == UIDensity.cozy;

    return Semantics(
      label: composeConversationItemSemanticsLabel(
        displayName: displayName,
        unreadCount: conv.unreadCount,
        mentionCount: conv.mentionCount,
        muted: conv.isMuted,
        snippet: snippet,
      ),
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              focusColor: context.accentLight,
              onHover: (hovered) => setState(() => _isHovered = hovered),
              onTap: widget.onTap,
              onSecondaryTapUp: (details) {
                widget.onContextMenu?.call(details.globalPosition);
              },
              // Mobile long-press now routes through the same
              // onContextMenu callback as desktop right-click — the
              // parent (conversation_panel) opens the centralised
              // EchoContextMenu so the item itself no longer carries
              // its own bottom-sheet implementation. The anchor
              // coordinate is irrelevant on mobile (renders as a
              // bottom sheet), so Offset.zero is a fine sentinel.
              onLongPress: _enableLongPressMenu
                  ? () => widget.onContextMenu?.call(Offset.zero)
                  : null,
              child: AnimatedContainer(
                duration: MotionDurations.quick,
                curve: MotionCurves.emphasis,
                height: conversationItemHeightFor(density),
                margin: const EdgeInsets.symmetric(vertical: 1),
                decoration: BoxDecoration(
                  color: _resolveBackgroundColor(context, hasUnread),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: _resolveHorizontalPadding(isCozy, isCompact),
                ),
                // Visual children re-announce muted/unread/timestamp via
                // their own Semantics nodes; suppress those so the composed
                // outer label is the single announcement (#631).
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      _buildAvatarStack(
                        context,
                        conv,
                        displayName,
                        density: density,
                      ),
                      SizedBox(width: _resolveAvatarSpacing(isCozy, isCompact)),
                      _buildNameAndSnippet(
                        context,
                        displayName: displayName,
                        snippet: snippet,
                        hasUnread: hasUnread,
                        conv: conv,
                        density: density,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Active-conversation accent pill — 4px wide left-edge marker
            // with fully rounded ends so it reads as a Discord-style
            // selection pill rather than a sharp-cornered bar.
            // IgnorePointer so taps pass through to the InkWell.
            if (widget.isSelected)
              Positioned(
                left: 0,
                top: 6,
                bottom: 6,
                child: IgnorePointer(
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: context.activeRowAccent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _resolveBackgroundColor(BuildContext context, bool hasUnread) {
    if (widget.isSelected) return context.accentLight;
    if (_isHovered) return context.surfaceHover;
    if (hasUnread && !widget.conversation.isMuted) {
      return context.unreadRowTint;
    }
    return Colors.transparent;
  }

  double _resolveHorizontalPadding(bool isCozy, bool isCompact) {
    if (isCozy) return 14;
    return isCompact ? 10 : 12;
  }

  double _resolveAvatarSpacing(bool isCozy, bool isCompact) {
    if (isCozy) return 14;
    return isCompact ? 8 : 12;
  }

  Color _resolveTimestampColor(BuildContext context, bool hasUnread) {
    if (widget.conversation.isMuted) return context.mutedSurface;
    return hasUnread ? context.accent : context.textMuted;
  }

  Widget _buildAvatarStack(
    BuildContext context,
    Conversation conv,
    String displayName, {
    UIDensity density = UIDensity.normal,
  }) {
    // Density tier sizes (UX roadmap Phase 2):
    //   compact -> 14px radius (28px diameter), 10px dot, 14px group icon
    //   normal  -> 20px radius (40px diameter), 12px dot, 18px group icon
    //   cozy    -> 22px radius (44px diameter), 13px dot, 20px group icon
    final double avatarRadius = switch (density) {
      UIDensity.cozy => 22,
      UIDensity.normal => 20,
      UIDensity.compact => 14,
    };
    final double dotSize = switch (density) {
      UIDensity.cozy => 13,
      UIDensity.normal => 12,
      UIDensity.compact => 10,
    };
    final double groupIconSize = switch (density) {
      UIDensity.cozy => 20,
      UIDensity.normal => 18,
      UIDensity.compact => 14,
    };
    return Stack(
      children: [
        buildAvatar(
          name: displayName,
          radius: avatarRadius,
          imageUrl: conv.isGroup ? widget.groupIconUrl : widget.peerAvatarUrl,
          bgColor: conv.isGroup ? groupAvatarColor(displayName) : null,
          fallbackIcon: conv.isGroup
              ? Icon(
                  Icons.group,
                  size: groupIconSize,
                  color: Theme.of(context).colorScheme.onPrimary,
                )
              : null,
        ),
        if (!conv.isGroup)
          Positioned(
            bottom: 0,
            right: 0,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Presence dot at full opacity for clarity
                AnimatedContainer(
                  duration: MotionDurations.gentle,
                  curve: MotionCurves.emphasis,
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    color: presenceColor(
                      widget.peerPresenceStatus,
                      isOnline: widget.isPeerOnline,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(color: context.sidebarBg, width: 2),
                  ),
                ),
                // Mute-bell overlay for muted conversations
                if (conv.isMuted)
                  Positioned(
                    bottom: -2,
                    right: -2,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.sidebarBg,
                      ),
                      padding: const EdgeInsets.all(1),
                      child: Icon(
                        Icons.notifications_off_outlined,
                        size: 8,
                        color: context.textMuted,
                      ),
                    ),
                  ),
              ],
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
    UIDensity density = UIDensity.normal,
  }) {
    final peer = conv.isGroup
        ? null
        : conv.members.where((m) => m.userId != widget.myUserId).firstOrNull;
    final statusText = peer?.statusText;
    final double statusFontSize = switch (density) {
      UIDensity.cozy => 12,
      UIDensity.normal => 11,
      UIDensity.compact => 10,
    };
    final double snippetGap = switch (density) {
      UIDensity.cozy => 6,
      UIDensity.normal => 4,
      UIDensity.compact => 1,
    };

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildNameRow(context, displayName, hasUnread, density: density),
          if (statusText != null && statusText.isNotEmpty) ...[
            const SizedBox(height: 1),
            Text(
              statusText,
              style: GoogleFonts.inter(
                fontSize: statusFontSize,
                color: context.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ] else if (snippet != null) ...[
            SizedBox(height: snippetGap),
            _buildSnippetRow(
              context,
              snippet,
              hasUnread,
              conv,
              density: density,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNameRow(
    BuildContext context,
    String displayName,
    bool hasUnread, {
    UIDensity density = UIDensity.normal,
  }) {
    final conv = widget.conversation;
    final showGroupOnline = conv.isGroup && widget.onlineMemberCount > 0;
    final rightSlot = _buildNameRowRightSlot(context, displayName, hasUnread);

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
          child: Row(
            children: [
              Expanded(
                child: Text(
                  displayName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: GoogleFonts.inter(
                    fontSize: switch (density) {
                      UIDensity.cozy => 15,
                      UIDensity.normal => 14,
                      UIDensity.compact => 13,
                    },
                    fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
                    color: conv.isMuted
                        ? context.textMuted
                        : context.textPrimary,
                  ),
                ),
              ),
              if (conv.isGroup)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.group_outlined,
                    size: 14,
                    color: context.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        if (showGroupOnline)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _buildGroupOnlineBadge(),
          ),
        Padding(padding: const EdgeInsets.only(left: 6), child: rightSlot),
      ],
    );
  }

  /// Right-side slot of the name row: "more" button on hover (desktop) or
  /// timestamp with optional status tick.
  Widget _buildNameRowRightSlot(
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

    if (showMoreButton) {
      return Semantics(
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
    }

    if (widget.timestamp.isNotEmpty) {
      // If the conversation's latest message is one we sent, show a Signal-
      // style status tick next to the timestamp (#507). Falls back silently
      // when local chat state hasn't loaded the conversation yet.
      final tick = _buildOwnStatusTick(context);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tick != null) ...[tick, const SizedBox(width: 4)],
          Text(
            widget.timestamp,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: _resolveTimestampColor(context, hasUnread),
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  /// Green pill badge showing how many group members are currently online.
  Widget _buildGroupOnlineBadge() {
    return Container(
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
    // Selector: only watch the last message of *this* conversation so that
    // messages arriving in other conversations don't trigger a rebuild here
    // (#578). The spread-copy fix in #676 keeps unaffected list references
    // stable, so select() equality holds for untouched conversations.
    final last = ref.watch(
      chatProvider.select((s) => s.messagesByConversation[conv.id]?.lastOrNull),
    );
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
    Conversation conv, {
    UIDensity density = UIDensity.normal,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildSnippetText(context, snippet, hasUnread, conv, density),
        ),
        if (conv.isMuted)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(
              Icons.notifications_off_outlined,
              size: 16,
              color: context.mutedSurface,
            ),
          ),
        // Mention badge sits to the LEFT of the unread count badge so it
        // remains visible when the unread count is multi-digit.  Distinct
        // color (mentionBadgeBg) so "you were mentioned" reads differently
        // from "X unread."
        if (conv.mentionCount > 0)
          Semantics(
            label: '${conv.mentionCount} mentions',
            child: Container(
              margin: const EdgeInsets.only(left: 8),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: context.mentionBadgeBg,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const ExcludeSemantics(
                child: Text(
                  '@',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        if (hasUnread) _buildUnreadBadge(context, conv, density),
      ],
    );
  }

  /// The text (or draft RichText) portion of the snippet row.
  Widget _buildSnippetText(
    BuildContext context,
    String snippet,
    bool hasUnread,
    Conversation conv,
    UIDensity density,
  ) {
    final showDraft = _draft != null && !hasUnread;
    final snippetWeight = hasUnread ? FontWeight.w500 : FontWeight.normal;
    final double snippetFontSize = switch (density) {
      UIDensity.cozy => 14,
      UIDensity.normal => 13,
      UIDensity.compact => 11,
    };

    if (showDraft) {
      return RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          children: [
            TextSpan(
              text: 'Draft: ',
              style: GoogleFonts.inter(
                fontSize: snippetFontSize,
                color: EchoTheme.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: _draft,
              style: GoogleFonts.inter(
                fontSize: snippetFontSize,
                color: context.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    return Text(
      snippet,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.inter(
        fontSize: snippetFontSize,
        color: conv.isMuted ? context.mutedSurface : context.textMuted,
        fontWeight: snippetWeight,
      ),
    );
  }

  /// Circular unread-count badge. 20×20 for cozy/normal, 16×16 for compact.
  Widget _buildUnreadBadge(
    BuildContext context,
    Conversation conv,
    UIDensity density,
  ) {
    final isCompact = density == UIDensity.compact;
    return Semantics(
      label: '${widget.conversation.unreadCount} unread messages',
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        // 20×20 for cozy/normal density, 16×16 for compact, per the
        // design canvas. Muted conversations keep the dim grey style.
        constraints: BoxConstraints(
          minWidth: isCompact ? 16 : 20,
          minHeight: isCompact ? 16 : 20,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: conv.isMuted ? context.surfaceHover : context.accent,
          shape: BoxShape.circle,
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
              fontSize: isCompact ? 10 : 11,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
