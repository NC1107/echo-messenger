import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/echo_theme.dart';

/// The "edited" marker on a message, in one of two styles — one source so the
/// two treatments can't drift:
/// - [inline] (grouped messages): a subtle italic `(edited)` below the bubble.
/// - default (last-in-group, metadata row): a Slack-style `edited` pill that
///   reads as a label rather than part of the timestamp.
class EditedBadge extends StatelessWidget {
  const EditedBadge({super.key, this.inline = false});

  final bool inline;

  @override
  Widget build(BuildContext context) {
    if (inline) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '(edited)',
          style: GoogleFonts.inter(
            fontSize: 11,
            fontStyle: FontStyle.italic,
            color: context.textMuted,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: context.surfaceHover,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'edited',
          style: GoogleFonts.inter(
            fontSize: 9,
            fontWeight: FontWeight.w500,
            color: context.textMuted,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
