import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

/// Retry / delete affordance shown below a failed outbound message.
/// Extracted from `message_item.dart` (#refactor-2026-05-09).  Either
/// callback may be null; if both are null only the failure label
/// renders.
class RetryRow extends StatelessWidget {
  final ChatMessage message;
  final ValueChanged<ChatMessage>? onRetry;
  final ValueChanged<ChatMessage>? onDelete;

  const RetryRow({
    super.key,
    required this.message,
    this.onRetry,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4, right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: EchoTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: EchoTheme.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const Icon(Icons.error_rounded, size: 16, color: EchoTheme.danger),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message.content.contains('not have been delivered')
                  ? 'Message may not have been delivered'
                  : 'Failed to send',
              style: const TextStyle(
                fontSize: 12,
                color: EchoTheme.danger,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => onRetry!(message),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: context.accent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Retry',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: context.onAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (onDelete != null) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => onDelete!(message),
              child: Text(
                'Delete',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: EchoTheme.danger.withValues(alpha: 0.8),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
