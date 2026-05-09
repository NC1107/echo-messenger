import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

/// Tappable "X replies" pill shown beneath a message that has at least
/// one threaded reply.  Aligns to the bubble's own side (right for
/// "my" messages in bubbles layout, left otherwise).  Tapping fires
/// [onTap] -- typically opens the thread view.
class ReplyCountBadge extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  final ValueChanged<ChatMessage>? onTap;

  const ReplyCountBadge({
    super.key,
    required this.message,
    required this.isMine,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final count = message.replyCount;
    final label = count == 1 ? '1 reply' : '$count replies';
    return Padding(
      padding: EdgeInsets.only(top: 4, left: isMine ? 0 : 36),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Semantics(
          label: 'View $label',
          button: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap == null ? null : () => onTap!(message),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: context.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.forum_outlined, size: 12, color: context.accent),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: context.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
