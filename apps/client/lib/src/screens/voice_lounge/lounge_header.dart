/// Header bar shown at the top of the voice lounge in portrait mode.
library;

import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class LoungeHeader extends StatelessWidget {
  final String channelName;
  final int participantCount;
  final VoidCallback? onBackToChat;
  final bool membersSidebarCollapsed;
  final VoidCallback? onToggleMembers;

  /// Optional metrics chip (call duration + ping). Rendered to the right
  /// of the participant count when present so it sits at eye-level with
  /// the channel name. Null in tests / when metrics aren't ready.
  final Widget? trailing;

  const LoungeHeader({
    super.key,
    required this.channelName,
    required this.participantCount,
    this.onBackToChat,
    this.membersSidebarCollapsed = false,
    this.onToggleMembers,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final participantTooltip =
        '$participantCount participant${participantCount != 1 ? 's' : ''}';
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          // Compact back: chevron only. The previous "Back to chat" text
          // button ate ~110 px and collided with the call-metrics chip
          // + participant pill on phones (user feedback 2026-05-28).
          if (onBackToChat != null)
            IconButton(
              tooltip: 'Back to chat',
              onPressed: onBackToChat,
              icon: const Icon(Icons.chevron_left, size: 24),
              style: IconButton.styleFrom(
                foregroundColor: context.textSecondary,
                minimumSize: const Size(40, 40),
                padding: EdgeInsets.zero,
              ),
            ),
          const Icon(Icons.graphic_eq, size: 18, color: EchoTheme.online),
          const SizedBox(width: 6),
          // Lounge name takes whatever space is left, ellipsis-truncated
          // if needed so the trailing metrics/eye don't get pushed off
          // the right edge of a narrow phone.
          Flexible(
            child: Text(
              channelName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Icon + number instead of "N participant(s)". The full text
          // moves to a tooltip so screen readers + hover users still get it.
          Tooltip(
            message: participantTooltip,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: context.surfaceHover,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 12,
                    color: context.textSecondary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '$participantCount',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
          const Spacer(),
          if (onToggleMembers != null)
            IconButton(
              tooltip: membersSidebarCollapsed
                  ? 'Show members'
                  : 'Hide members',
              onPressed: onToggleMembers,
              icon: Icon(
                membersSidebarCollapsed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
              ),
              style: IconButton.styleFrom(
                foregroundColor: context.textSecondary,
                minimumSize: const Size(40, 40),
                padding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
    );
  }
}
