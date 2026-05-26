// Welcome card shown at the top of a conversation with no earlier history,
// modelled on Discord/Slack's "This is the start of #channel-name" hero.
// Replaces the thin "Start of conversation" date divider when the chat
// has genuinely loaded everything.
import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../theme/echo_theme.dart';

class WelcomeCard extends StatelessWidget {
  final Conversation conversation;
  final String myUserId;

  const WelcomeCard({
    super.key,
    required this.conversation,
    required this.myUserId,
  });

  @override
  Widget build(BuildContext context) {
    final isGroup = conversation.isGroup;
    final name = conversation.displayName(myUserId);
    final title = isGroup ? 'Welcome to $name!' : name;
    final subtitle = isGroup
        ? 'This is the start of the $name group. Say hi to break the ice.'
        : 'This is the beginning of your direct message history with $name.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: context.accent.withValues(alpha: 0.15),
            ),
            alignment: Alignment.center,
            child: Icon(
              isGroup ? Icons.groups_outlined : Icons.chat_bubble_outline,
              size: 36,
              color: context.accent,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: context.border.withValues(alpha: 0.5)),
        ],
      ),
    );
  }
}
