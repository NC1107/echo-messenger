// Empty-state shown inside a 1:1 chat with no messages yet.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class EmptyMessagePlaceholder extends StatelessWidget {
  final String displayName;
  final VoidCallback onSayHi;

  const EmptyMessagePlaceholder({
    super.key,
    required this.displayName,
    required this.onSayHi,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: context.accent,
            child: Text(
              displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
              style: const TextStyle(fontSize: 22, color: Colors.white),
            ),
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
