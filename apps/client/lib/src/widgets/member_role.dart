/// Owner / admin role indicators reused across every member listing.
///
/// Before this file the same `Icons.star_rounded (amber)` /
/// `Icons.shield_rounded (blue)` pattern and the same Owner / Admin
/// pill ran inline in `members_panel.dart`, `group_members_sheet.dart`
/// and `group_info_screen.dart`. Each copy chose its own padding,
/// font-size and corner radius — close, but visibly off. These two
/// widgets are the one place to render either treatment.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/echo_theme.dart';

/// A small inline icon used next to a member's username to indicate
/// their role. Returns an empty box for ordinary members so callers
/// can drop it into a Row unconditionally without a null check.
class MemberRoleIcon extends StatelessWidget {
  final String? role;
  final double size;
  const MemberRoleIcon({super.key, required this.role, this.size = 14});

  @override
  Widget build(BuildContext context) {
    if (role == 'owner') {
      return Icon(
        Icons.star_rounded,
        size: size,
        color: Colors.amber,
        semanticLabel: 'owner',
      );
    }
    if (role == 'admin') {
      return Icon(
        Icons.shield_rounded,
        size: size,
        color: Colors.blue,
        semanticLabel: 'admin',
      );
    }
    return const SizedBox.shrink();
  }
}

/// The Owner / Admin pill rendered to the right of a member's name.
/// Renders nothing for ordinary members so callers can drop it into a
/// Row unconditionally.
class MemberRoleBadge extends StatelessWidget {
  final String? role;
  final EdgeInsetsGeometry margin;
  const MemberRoleBadge({
    super.key,
    required this.role,
    this.margin = const EdgeInsets.only(left: 8),
  });

  @override
  Widget build(BuildContext context) {
    if (role != 'owner' && role != 'admin') return const SizedBox.shrink();
    final isOwner = role == 'owner';
    // Owner uses accentHover (not amber) — amber is reserved for actual warnings.
    final bgColor = isOwner
        ? EchoTheme.accentHover.withValues(alpha: 0.22)
        : context.accent.withValues(alpha: 0.15);
    final textColor = isOwner ? EchoTheme.accentHover : context.accentHover;
    final label = isOwner ? 'Owner' : 'Admin';

    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
