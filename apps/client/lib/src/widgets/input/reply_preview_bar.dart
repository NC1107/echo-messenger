import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

/// Shows a reply-to preview bar above the input field.
///
/// Displays the original message author, a truncated preview of their message,
/// and a dismiss button.
class ReplyPreviewBar extends StatelessWidget {
  final ChatMessage replyToMessage;
  final VoidCallback onDismiss;

  const ReplyPreviewBar({
    super.key,
    required this.replyToMessage,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final truncated = replyToMessage.content.length > 120
        ? '${replyToMessage.content.substring(0, 120)}...'
        : replyToMessage.content;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: context.accent, width: 3)),
      ),
      child: Row(
        children: [
          Icon(Icons.reply_outlined, size: 14, color: context.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to ${replyToMessage.fromUsername}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: context.accent,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  truncated,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onDismiss,
            child: Icon(Icons.close, size: 14, color: context.textMuted),
          ),
        ],
      ),
    );
  }
}
