/// Header bar shown at the top of the voice lounge in portrait mode.
library;

import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class LoungeHeader extends StatelessWidget {
  final String channelName;
  final int participantCount;
  final VoidCallback? onBackToChat;

  const LoungeHeader({
    super.key,
    required this.channelName,
    required this.participantCount,
    this.onBackToChat,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq, size: 20, color: EchoTheme.online),
          const SizedBox(width: 10),
          Text(
            channelName,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: context.surfaceHover,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$participantCount participant${participantCount != 1 ? 's' : ''}',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Spacer(),
          if (onBackToChat != null)
            TextButton.icon(
              onPressed: onBackToChat,
              icon: const Icon(Icons.chat_outlined, size: 16),
              label: const Text('Back to chat'),
              style: TextButton.styleFrom(
                foregroundColor: context.textSecondary,
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}
