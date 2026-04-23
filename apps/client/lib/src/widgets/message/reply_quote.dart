import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Displays a reply-to quote block with a colored left border, username, and
/// truncated content.
class ReplyQuote extends StatelessWidget {
  final String? replyToUsername;
  final String replyToContent;
  final bool isMine;
  final VoidCallback? onTap;

  const ReplyQuote({
    super.key,
    required this.replyToUsername,
    required this.replyToContent,
    required this.isMine,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final truncated = replyToContent.length > 100
        ? '${replyToContent.substring(0, 100)}...'
        : replyToContent;

    return Semantics(
      label: onTap != null
          ? 'Jump to original message from ${replyToUsername ?? 'Unknown'}'
          : 'In reply to ${replyToUsername ?? 'Unknown'}: $truncated',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: (isMine ? Colors.white : context.accent).withValues(
              alpha: 0.12,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border(
              left: BorderSide(
                color: isMine
                    ? Colors.white.withValues(alpha: 0.5)
                    : context.accent,
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                replyToUsername ?? 'Unknown',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isMine
                      ? Colors.white.withValues(alpha: 0.8)
                      : context.accent,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                truncated,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isMine
                      ? Colors.white.withValues(alpha: 0.7)
                      : context.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
