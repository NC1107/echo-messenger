// Empty-state shown inside a 1:1 chat with no messages yet.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import '../user_avatar.dart';

class EmptyMessagePlaceholder extends StatelessWidget {
  final String userId;
  final String displayName;
  final String? avatarUrl;
  final VoidCallback onSayHi;

  const EmptyMessagePlaceholder({
    super.key,
    required this.userId,
    required this.displayName,
    required this.onSayHi,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          UserAvatar(
            userId: userId,
            username: displayName,
            avatarUrl: avatarUrl,
            radius: 28,
            bgColor: context.accent,
            openProfileOnTap: false,
          ),
          const SizedBox(height: 12),
          Text(
            displayName,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Start your conversation with $displayName',
            style: TextStyle(color: context.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Semantics(
            label: 'Say hi to $displayName',
            button: true,
            child: TextButton(
              onPressed: onSayHi,
              style: TextButton.styleFrom(
                foregroundColor: context.accent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: context.accent.withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: const Text(
                'Say hi \u{1F44B}',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
