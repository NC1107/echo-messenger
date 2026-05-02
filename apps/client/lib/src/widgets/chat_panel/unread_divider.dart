// Accent-colored divider with "N new message(s)" label.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class UnreadDivider extends StatelessWidget {
  final int count;

  const UnreadDivider({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final noun = count == 1 ? 'message' : 'messages';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: context.accent, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '$count new $noun',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.accent,
              ),
            ),
          ),
          Expanded(child: Divider(color: context.accent, height: 1)),
        ],
      ),
    );
  }
}
