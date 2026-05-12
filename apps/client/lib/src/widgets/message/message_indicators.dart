import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

/// Small in-bubble indicators (pinned, forwarded, lock, decrypt-failure)
/// extracted from `message_item.dart` (#refactor-2026-05-09).  Each one is
/// a pure stateless renderer with no closure over the parent state, so
/// callers just instantiate the widget directly inside `_bubbleChildren`.

/// Pin badge shown at the top of a pinned message's bubble.
class PinnedIndicator extends StatelessWidget {
  final bool isMine;

  const PinnedIndicator({super.key, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final color = isMine
        ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)
        : context.accent;
    return Semantics(
      label: 'Pinned message',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.push_pin, size: 11, color: color),
            const SizedBox(width: 3),
            Text(
              'Pinned',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Forwarded" italic label shown when a message starts with the
/// forward-prefix sentinel.
class ForwardedBadge extends StatelessWidget {
  final bool isMine;

  const ForwardedBadge({super.key, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final color = isMine
        ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)
        : context.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forward, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            'Forwarded',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tiny encryption-status lock shown next to a message timestamp.  Tapping
/// it on the recipient side surfaces the identity-verification screen via
/// [onVerifyIdentity]; sender's own lock is non-interactive.
class LockIcon extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  final ValueChanged<ChatMessage>? onVerifyIdentity;

  const LockIcon({
    super.key,
    required this.message,
    required this.isMine,
    this.onVerifyIdentity,
  });

  @override
  Widget build(BuildContext context) {
    final icon = Padding(
      padding: const EdgeInsets.only(left: 3),
      child: Icon(Icons.lock, size: 10, color: context.textMuted),
    );

    if (isMine || onVerifyIdentity == null) {
      return icon;
    }

    return Tooltip(
      message: 'End-to-end encrypted. Tap to verify.',
      child: InkWell(
        onTap: () => onVerifyIdentity!(message),
        borderRadius: BorderRadius.circular(6),
        child: icon,
      ),
    );
  }
}

/// Soft pill shown in place of a message body when decryption fails and
/// the user has opted to keep the row visible (#668).
class DecryptFailurePill extends StatelessWidget {
  const DecryptFailurePill({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Message could not be decrypted',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: context.textMuted.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 16, color: context.textSecondary),
            const SizedBox(width: 6),
            Text(
              'Message could not be decrypted',
              style: GoogleFonts.inter(
                fontStyle: FontStyle.italic,
                color: context.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
