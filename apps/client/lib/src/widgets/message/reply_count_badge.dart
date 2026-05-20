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

  /// When true, render as a subtle inline accent-coloured "N replies" link
  /// (no rounded pill). Used by the plain (Slack-style) layout where the
  /// chrome of a pill clashes with the surrounding text-only treatment.
  final bool inlineStyle;

  /// Whether the local user has unread replies on this thread. When true,
  /// a small accent-coloured dot renders on the badge so the user can
  /// spot fresh activity without opening the thread (#449-3).
  ///
  /// Today no call site wires this — the unread-tracking state path
  /// (last-viewed-reply timestamp, per-thread, persisted) is deferred
  /// to a separate change. The prop is plumbed now so the visual
  /// affordance is in place and a follow-up only has to flip the bool.
  final bool hasUnread;

  const ReplyCountBadge({
    super.key,
    required this.message,
    required this.isMine,
    this.onTap,
    this.inlineStyle = false,
    this.hasUnread = false,
  });

  Widget _unreadDot(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: context.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = message.replyCount;
    final label = count == 1 ? '1 reply' : '$count replies';
    if (inlineStyle) {
      return Padding(
        padding: EdgeInsets.only(top: 2, left: isMine ? 0 : 36),
        child: Align(
          alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
          child: Semantics(
            label: hasUnread ? 'View $label (new replies)' : 'View $label',
            button: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(2),
              onTap: onTap == null ? null : () => onTap!(message),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: context.accent,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.underline,
                      decorationColor: context.accent.withValues(alpha: 0.4),
                    ),
                  ),
                  if (hasUnread) _unreadDot(context),
                ],
              ),
            ),
          ),
        ),
      );
    }
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
                    if (hasUnread) _unreadDot(context),
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
