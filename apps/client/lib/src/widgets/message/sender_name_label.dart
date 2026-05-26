import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/chat_message.dart';
import '../../providers/theme_provider.dart' show UIDensity;
import '../../theme/echo_theme.dart';
import '../../utils/time_utils.dart';
import '../avatar_utils.dart' show senderLabelColor;

/// Sender name shown above a group message bubble.  In compact / plain
/// layouts the name and timestamp share a single inline row to save
/// vertical space; in bubbles layout the name stands alone above the
/// bubble.  Density drives the font sizes on both halves.
class SenderNameLabel extends StatelessWidget {
  final ChatMessage message;
  final bool hasMedia;
  final bool compactLayout;
  final UIDensity density;

  const SenderNameLabel({
    super.key,
    required this.message,
    required this.hasMedia,
    required this.compactLayout,
    required this.density,
  });

  @override
  Widget build(BuildContext context) {
    final double nameFontSize = switch (density) {
      UIDensity.cozy => 14,
      UIDensity.normal => 13,
      UIDensity.compact => 12,
    };
    final double timestampFontSize = switch (density) {
      UIDensity.cozy => 12,
      UIDensity.normal => 11,
      UIDensity.compact => 10,
    };

    final nameText = Text(
      message.fromUsername,
      style: GoogleFonts.inter(
        fontSize: nameFontSize,
        fontWeight: FontWeight.w600,
        color: senderLabelColor(message.fromUsername),
      ),
    );

    // Compact density gets ~IRC-style chrome: zero bottom gap between
    // header and body so name+timestamp read as a prefix line, not a
    // separate paragraph. Bubbles/non-compact keep the small breathing
    // gap that lets the bold name stand off the body text.
    final bottomGap = density == UIDensity.compact ? 0.0 : 4.0;
    final padding = EdgeInsets.only(bottom: bottomGap, left: hasMedia ? 8 : 0);

    if (!compactLayout) {
      return Padding(padding: padding, child: nameText);
    }

    return Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          nameText,
          const SizedBox(width: 6),
          Text(
            formatMessageTimestamp(message.timestamp),
            style: GoogleFonts.inter(
              fontSize: timestampFontSize,
              color: context.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
