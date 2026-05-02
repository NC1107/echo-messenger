// Empty-state shown when no conversation is selected in the chat panel.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class NoConversationPlaceholder extends StatelessWidget {
  const NoConversationPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final gradient = context.chatBgGradient;
    return DecoratedBox(
      decoration: gradient != null
          ? BoxDecoration(gradient: gradient)
          : BoxDecoration(color: context.chatBg),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_rounded,
              size: 56,
              color: context.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 20),
            Text(
              'No conversation selected',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a conversation from the sidebar or start a new one',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
