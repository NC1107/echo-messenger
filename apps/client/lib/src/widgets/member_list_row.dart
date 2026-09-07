import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/user_presence_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/presence.dart';
import 'member_role.dart';
import 'user_avatar.dart';

/// Visual density of a [MemberListRow].
///
/// `compact` is the desktop member rail (tighter, leading role icon);
/// `comfortable` is the mobile members sheet and group-info roster (roomier,
/// trailing role pill).
enum MemberRowDensity { compact, comfortable }

class _RowMetrics {
  const _RowMetrics(this.avatarRadius, this.minHeight, this.vPad, this.hPad);
  final double avatarRadius;
  final double minHeight;
  final double vPad;
  final double hPad;
}

const _RowMetrics _compactMetrics = _RowMetrics(16, 44, 6, 12);
const _RowMetrics _comfortableMetrics = _RowMetrics(18, 56, 8, 16);

/// One member roster row, shared by the desktop rail, the mobile members
/// sheet and the group-info roster.
///
/// Owns every *visual* decision — avatar size, name weight/colour, the
/// presence/status secondary line, role indicator (leading icon in `compact`,
/// trailing pill in `comfortable`), hover/ripple, and the screen-reader label.
/// Callers keep their own *behaviour* (open profile, remove, context menu) by
/// injecting it via [onTap]/[onSecondaryTapDown]/[onLongPress] and the
/// [trailing] / [hoverTrailing] slots, so the three surfaces stay visually
/// identical while differing only where they should.
class MemberListRow extends ConsumerStatefulWidget {
  const MemberListRow({
    super.key,
    required this.member,
    this.isMe = false,
    this.density = MemberRowDensity.comfortable,
    this.onTap,
    this.onSecondaryTapDown,
    this.onLongPress,
    this.trailing,
    this.hoverTrailing,
    this.showSecondaryLine = true,
  });

  final ConversationMember member;
  final bool isMe;
  final MemberRowDensity density;
  final VoidCallback? onTap;

  /// Right-click on desktop / context-menu anchor (carries the tap position).
  final GestureTapDownCallback? onSecondaryTapDown;
  final VoidCallback? onLongPress;

  /// Always-visible trailing widget (e.g. a `more_vert` menu button, or an
  /// in-flight spinner). Occupies a fixed 44px slot so names never reflow.
  final Widget? trailing;

  /// Trailing widget revealed only while the row is hovered (desktop), e.g. a
  /// remove button. Shares the same 44px slot as [trailing].
  final Widget? hoverTrailing;

  /// Whether to render the presence/status line beneath the name.
  final bool showSecondaryLine;

  @override
  ConsumerState<MemberListRow> createState() => _MemberListRowState();
}

class _MemberListRowState extends ConsumerState<MemberListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final role = m.role;
    final isPrivileged = role == 'owner' || role == 'admin';
    final compact = widget.density == MemberRowDensity.compact;
    final metrics = compact ? _compactMetrics : _comfortableMetrics;

    // Self presence comes from auth (the WS doesn't echo our own status);
    // everyone else reads the centralized presence provider.
    final UserPresence presence;
    final String? customStatus;
    if (widget.isMe) {
      presence = UserPresence(
        status: ref.watch(authProvider.select((a) => a.presenceStatus)),
        isOnline: true,
      );
      customStatus = ref.watch(authProvider.select((a) => a.statusText));
    } else {
      presence = ref.watch(userPresenceProvider(m.userId));
      customStatus = m.statusText;
    }
    final secondary = (customStatus != null && customStatus.trim().isNotEmpty)
        ? customStatus
        : presenceLabel(presence.status, isOnline: presence.isOnline);

    final nameStack = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (compact && isPrivileged) ...[
              ExcludeSemantics(child: MemberRoleIcon(role: role)),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                m.username,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (!compact)
              MemberRoleBadge(
                role: role,
                margin: const EdgeInsets.only(left: 6),
              ),
          ],
        ),
        if (widget.showSecondaryLine) ...[
          const SizedBox(height: 2),
          Text(
            secondary,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ],
      ],
    );

    final hasTrailingSlot =
        widget.trailing != null || widget.hoverTrailing != null;
    final revealed = _hovered
        ? (widget.hoverTrailing ?? widget.trailing)
        : widget.trailing;

    Widget interactive = InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      hoverColor: context.surfaceHover,
      borderRadius: BorderRadius.circular(EchoRadii.md),
      child: Container(
        constraints: BoxConstraints(minHeight: metrics.minHeight),
        padding: EdgeInsets.symmetric(
          horizontal: metrics.hPad,
          vertical: metrics.vPad,
        ),
        child: Row(
          children: [
            UserAvatar(
              userId: m.userId,
              username: m.username,
              avatarUrl: m.avatarUrl,
              radius: metrics.avatarRadius,
              showPresence: true,
              openProfileOnTap: false,
            ),
            const SizedBox(width: 12),
            Expanded(child: nameStack),
            if (hasTrailingSlot)
              SizedBox(
                width: 44,
                height: 44,
                child: Center(child: revealed ?? const SizedBox.shrink()),
              ),
          ],
        ),
      ),
    );

    if (widget.onSecondaryTapDown != null) {
      interactive = GestureDetector(
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: interactive,
      );
    }

    final roleLabel = role == 'owner'
        ? 'owner'
        : (role == 'admin' ? 'admin' : null);
    final semanticsLabel = [
      m.username,
      ?roleLabel,
      secondary,
      if (widget.isMe) 'you',
    ].join(', ');

    return Semantics(
      label: 'member: $semanticsLabel',
      button: true,
      child: MouseRegion(
        onEnter: widget.hoverTrailing == null
            ? null
            : (_) => setState(() => _hovered = true),
        onExit: widget.hoverTrailing == null
            ? null
            : (_) => setState(() => _hovered = false),
        child: interactive,
      ),
    );
  }
}
